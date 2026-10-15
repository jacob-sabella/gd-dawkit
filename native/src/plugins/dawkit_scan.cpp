// dawkit_scan: what plugins are in a file, found in a process of its own.
//
//   dawkit_scan CLAP <file.clap>
//   dawkit_scan VST3 <bundle.vst3>
//   dawkit_scan LV2                       every LV2 plugin installed (LV2_PATH, or the usual places)
//   dawkit_scan files <FORMAT> [dir...]   the plugin files under `dir`s (the usual places if none)
//   dawkit_scan --out <file> ...          the answer written to `file` instead of stdout
//
// Prints a JSON array on stdout: one object per plugin, {format, id, name, vendor, version, path,
// category, instrument, has_editor}, or one string per file for `files`. A plugin's own chatter
// goes to stderr. Exits 0 when it looked (even if it found nothing), 1 with the reason on stderr.
//
// Loading a plugin runs its code, and a plugin that crashes as it starts would take whatever
// loaded it down with it: the engine runs this instead, and a crash here costs one plugin's entry.

#include "hosted_plugin.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#ifdef _WIN32
#include <io.h>
#define dup _dup
#define dup2 _dup2
#define fdopen _fdopen
#else
#include <unistd.h>
#endif

using namespace dawkit;

static std::string json(const std::string &s) {
	std::string out = "\"";
	for (unsigned char c : s) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20) {
					char b[8];
					std::snprintf(b, sizeof b, "\\u%04x", c);
					out += b;
				} else {
					out += (char)c;
				}
		}
	}
	return out + "\"";
}

static std::string json(const PluginInfo &p) {
	return "{\"format\":" + json(p.format) + ",\"id\":" + json(p.id) + ",\"name\":" + json(p.name) +
			",\"vendor\":" + json(p.vendor) + ",\"version\":" + json(p.version) + ",\"path\":" + json(p.path) +
			",\"category\":" + json(p.category) + ",\"instrument\":" + (p.instrument ? "true" : "false") +
			",\"has_editor\":" + (p.has_editor ? "true" : "false") + "}";
}

int main(int argc, char **argv) {
	set_main_thread();
	const char *out_path = nullptr;
	if (argc >= 3 && std::string(argv[1]) == "--out") {
		out_path = argv[2];
		argv += 2;
		argc -= 2;
	}
	if (argc < 2) {
		std::fprintf(stderr, "usage: dawkit_scan CLAP|VST3 <path> | LV2 | files <FORMAT> [dir...]\n");
		return 1;
	}
	// Plugins print as they load; only the answer goes where the answer is read.
	std::fflush(stdout);
	int kept = dup(1);
	dup2(2, 1);
	FILE *answer = fdopen(kept, "w");
	std::string what = argv[1];
	std::string out = "[";
	std::string problem;
	if (what == "files") {
		if (argc < 3) {
			std::fprintf(stderr, "dawkit_scan files <FORMAT> [dir...]\n");
			return 1;
		}
		std::vector<std::string> dirs(argv + 3, argv + argc);
		if (dirs.empty()) {
			dirs = default_paths(argv[2]);
		}
		std::vector<std::string> files = find_plugin_files(argv[2], dirs);
		for (size_t i = 0; i < files.size(); i++) {
			out += (i ? "," : "") + json(files[i]);
		}
	} else {
		std::vector<PluginInfo> found;
		if (what == "LV2") {
			found = scan_lv2(problem);
		} else if (argc >= 3 && what == "CLAP") {
			found = scan_clap(argv[2], problem);
		} else if (argc >= 3 && what == "VST3") {
			found = scan_vst3(argv[2], problem);
		} else {
			std::fprintf(stderr, "dawkit_scan: no format '%s', or no path\n", what.c_str());
			return 1;
		}
		for (size_t i = 0; i < found.size(); i++) {
			out += (i ? "," : "") + json(found[i]);
		}
		if (found.empty() && !problem.empty()) {
			std::fprintf(stderr, "%s\n", problem.c_str());
		}
	}
	out += "]\n";
	if (out_path) {
		// Whole or not at all: whoever reads it may be watching for it to appear.
		std::string partial = std::string(out_path) + ".part";
		FILE *f = std::fopen(partial.c_str(), "wb");
		if (!f) {
			std::fprintf(stderr, "dawkit_scan: cannot write %s\n", out_path);
			std::_Exit(1);
		}
		std::fputs(out.c_str(), f);
		std::fclose(f);
		std::remove(out_path);
		std::rename(partial.c_str(), out_path);
	} else {
		std::fputs(out.c_str(), answer);
		std::fflush(answer);
	}
	// Not through the plugins' own teardown: some never expect to be unloaded, and the answer is out.
	std::_Exit(0);
}
