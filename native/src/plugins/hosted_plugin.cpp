#include "hosted_plugin.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <thread>

#ifndef _WIN32
#include <poll.h>
#endif

namespace fs = std::filesystem;

namespace dawkit {

// --- threads and time ---------------------------------------------------------------------------

static std::thread::id main_id;
static bool main_known = false;
// The load this thread stands in for the main thread for, or 0.
static thread_local int standing_in = 0;

void set_main_thread() {
	main_id = std::this_thread::get_id();
	main_known = true;
}

bool on_main_thread() {
	return standing_in != 0 || !main_known || std::this_thread::get_id() == main_id;
}

void stand_in_for_main(int owner) {
	standing_in = owner;
}

int loading_owner() {
	return standing_in;
}

std::mutex &load_lock() {
	static std::mutex m;
	return m;
}

double now_seconds() {
	using namespace std::chrono;
	return duration<double>(steady_clock::now().time_since_epoch()).count();
}

// --- the run loop -------------------------------------------------------------------------------

RunLoop &RunLoop::get() {
	static RunLoop loop;
	return loop;
}

int RunLoop::add_fd(int fd, Callback on_ready) {
	std::lock_guard<std::recursive_mutex> hold(lock);
	Entry e{ next_id++, fd, 0, 0.0, std::move(on_ready) };
	e.owner = loading_owner();
	entries.push_back(std::move(e));
	return entries.back().id;
}

int RunLoop::add_timer(int period_ms, Callback on_tick) {
	std::lock_guard<std::recursive_mutex> hold(lock);
	period_ms = std::max(period_ms, 1);
	Entry e{ next_id++, -1, period_ms, now_seconds() + period_ms / 1000.0, std::move(on_tick) };
	e.owner = loading_owner();
	entries.push_back(std::move(e));
	return entries.back().id;
}

void RunLoop::remove(int id) {
	std::lock_guard<std::recursive_mutex> hold(lock);
	for (Entry &e : entries) {
		if (e.id == id) {
			e.gone = true;
		}
	}
	if (!pumping) {
		entries.erase(std::remove_if(entries.begin(), entries.end(), [](const Entry &e) { return e.gone; }),
				entries.end());
	}
}

void RunLoop::release(int owner) {
	if (owner == 0) {
		return;
	}
	std::lock_guard<std::recursive_mutex> hold(lock);
	for (Entry &e : entries) {
		if (e.owner == owner) {
			e.owner = 0;
		}
	}
}

void RunLoop::pump() {
	// Copied out first, under the lock: a callback may add or remove entries (which would move the
	// vector), and a loading thread may add its own meanwhile. Called back with the lock let go.
	std::vector<std::pair<int, Callback>> due;
#ifndef _WIN32
	std::vector<pollfd> fds;
	std::vector<int> fd_ids;
#endif
	{
		std::lock_guard<std::recursive_mutex> hold(lock);
		if (pumping || entries.empty()) {
			return;
		}
		pumping = true;
		double now = now_seconds();
#ifndef _WIN32
		for (const Entry &e : entries) {
			if (!e.gone && e.fd >= 0 && e.owner == 0) {
				fds.push_back(pollfd{ e.fd, POLLIN, 0 });
				fd_ids.push_back(e.id);
			}
		}
#endif
		for (Entry &e : entries) {
			if (!e.gone && e.fd < 0 && e.owner == 0 && now >= e.due) {
				// Not caught up tick by tick after a long frame: once, and on from now.
				e.due = now + e.period_ms / 1000.0;
				due.push_back({ e.id, e.call });
			}
		}
	}
#ifndef _WIN32
	if (!fds.empty() && poll(fds.data(), fds.size(), 0) > 0) {
		std::lock_guard<std::recursive_mutex> hold(lock);
		for (size_t i = 0; i < fds.size(); i++) {
			if (fds[i].revents & (POLLIN | POLLHUP | POLLERR)) {
				for (const Entry &e : entries) {
					if (e.id == fd_ids[i] && !e.gone) {
						due.push_back({ e.id, e.call });
					}
				}
			}
		}
	}
#endif
	for (auto &d : due) {
		bool still = false;
		{
			std::lock_guard<std::recursive_mutex> hold(lock);
			for (const Entry &e : entries) {
				still = still || (e.id == d.first && !e.gone);
			}
		}
		if (still) {
			d.second();
		}
	}
	std::lock_guard<std::recursive_mutex> hold(lock);
	pumping = false;
	entries.erase(std::remove_if(entries.begin(), entries.end(), [](const Entry &e) { return e.gone; }),
			entries.end());
}

// --- the plugin's parameters, in common -------------------------------------------------------

void HostedPlugin::set_params(std::vector<ParamInfo> list) {
	params = std::move(list);
	values.reset(new std::atomic<double>[params.size() + 1]);
	changed.reset(new std::atomic<bool>[params.size() + 1]);
	for (size_t i = 0; i < params.size(); i++) {
		values[i].store(params[i].def);
		changed[i].store(false);
	}
}

double HostedPlugin::get_normalized(int i) const {
	if (i < 0 || i >= (int)params.size() || !values) {
		return 0.0;
	}
	return values[i].load();
}

void HostedPlugin::store_value(int i, double value, bool by_plugin) {
	if (i < 0 || i >= (int)params.size() || !values) {
		return;
	}
	value = std::clamp(value, 0.0, 1.0);
	double was = values[i].exchange(value);
	if (by_plugin && was != value) {
		changed[i].store(true);
		any_changed.store(true);
	}
}

std::vector<int> HostedPlugin::take_changed() {
	std::vector<int> out;
	if (!any_changed.exchange(false) || !changed) {
		return out;
	}
	for (size_t i = 0; i < params.size(); i++) {
		if (changed[i].exchange(false)) {
			out.push_back((int)i);
		}
	}
	return out;
}

void HostedPlugin::request_editor_size(int width, int height) {
	resize_w.store(width);
	resize_h.store(height);
	resized.store(true);
}

bool HostedPlugin::take_editor_resize(int &width, int &height) {
	if (!resized.exchange(false)) {
		return false;
	}
	width = resize_w.load();
	height = resize_h.load();
	return width > 0 && height > 0;
}

// --- where plugins are --------------------------------------------------------------------------

static std::string env(const char *name) {
	const char *v = std::getenv(name);
	return v ? std::string(v) : std::string();
}

static void split_into(const std::string &list, std::vector<std::string> &out) {
#ifdef _WIN32
	const char sep = ';';
#else
	const char sep = ':';
#endif
	size_t at = 0;
	while (at <= list.size()) {
		size_t end = list.find(sep, at);
		if (end == std::string::npos) {
			end = list.size();
		}
		if (end > at) {
			out.push_back(list.substr(at, end - at));
		}
		at = end + 1;
	}
}

std::vector<std::string> default_paths(const std::string &format) {
	std::vector<std::string> out;
	std::string home = env("HOME");
#ifdef _WIN32
	std::string common = env("COMMONPROGRAMFILES");
	std::string local = env("LOCALAPPDATA");
	if (format == "CLAP") {
		split_into(env("CLAP_PATH"), out);
		if (!common.empty()) out.push_back(common + "\\CLAP");
		if (!local.empty()) out.push_back(local + "\\Programs\\Common\\CLAP");
	} else if (format == "VST3") {
		if (!common.empty()) out.push_back(common + "\\VST3");
		if (!local.empty()) out.push_back(local + "\\Programs\\Common\\VST3");
	}
#else
	if (format == "CLAP") {
		split_into(env("CLAP_PATH"), out);
		if (!home.empty()) out.push_back(home + "/.clap");
		out.push_back("/usr/lib/clap");
		out.push_back("/usr/local/lib/clap");
	} else if (format == "VST3") {
		if (!home.empty()) out.push_back(home + "/.vst3");
		out.push_back("/usr/lib/vst3");
		out.push_back("/usr/local/lib/vst3");
	} else if (format == "LV2") {
		std::string given = env("LV2_PATH");
		if (!given.empty()) {
			split_into(given, out);
		} else {
			if (!home.empty()) out.push_back(home + "/.lv2");
			out.push_back("/usr/local/lib/lv2");
			out.push_back("/usr/lib/lv2");
		}
	}
#endif
	return out;
}

static bool ends_with(const std::string &s, const std::string &tail) {
	if (s.size() < tail.size()) {
		return false;
	}
	return std::equal(tail.rbegin(), tail.rend(), s.rbegin(),
			[](char a, char b) { return std::tolower((unsigned char)a) == std::tolower((unsigned char)b); });
}

static void find_in(const fs::path &dir, const std::string &ext, bool bundles, int depth,
		std::vector<std::string> &out) {
	std::error_code ec;
	if (depth > 8 || !fs::is_directory(dir, ec)) {
		return;
	}
	for (fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec), end; it != end;
			it.increment(ec)) {
		if (ec) {
			break;
		}
		const fs::path p = it->path();
		std::string name = p.filename().string();
		bool is_dir = fs::is_directory(p, ec);
		if (ends_with(name, ext)) {
			// A bundle is one plugin however much is in it; never looked into.
			if (is_dir == bundles || !bundles) {
				out.push_back(p.string());
			}
			continue;
		}
		if (is_dir) {
			find_in(p, ext, bundles, depth + 1, out);
		}
	}
}

std::vector<std::string> find_plugin_files(const std::string &format, const std::vector<std::string> &dirs) {
	std::vector<std::string> out;
	for (const std::string &d : dirs) {
		if (format == "CLAP") {
			find_in(d, ".clap", false, 0, out);
		} else if (format == "VST3") {
			find_in(d, ".vst3", false, 0, out);
		}
	}
	std::sort(out.begin(), out.end());
	out.erase(std::unique(out.begin(), out.end()), out.end());
	return out;
}

std::unique_ptr<HostedPlugin> load_plugin(const PluginInfo &info, std::string &problem) {
	if (info.format == "CLAP") {
		return load_clap(info.path, info.id, problem);
	}
	if (info.format == "VST3") {
		return load_vst3(info.path, info.id, problem);
	}
	if (info.format == "LV2") {
		return load_lv2(info.id, problem);
	}
	problem = "no such plugin format: " + info.format;
	return nullptr;
}

} // namespace dawkit
