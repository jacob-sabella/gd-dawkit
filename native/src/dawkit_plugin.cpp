#include "dawkit_plugin.h"

#include "plugins/editor_window.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <set>

using namespace godot;

namespace {

// Every plugin alive, for `pump`. The main thread's.
std::set<DawKitPlugin *> &alive() {
	static std::set<DawKitPlugin *> all;
	return all;
}

String str(const std::string &s) {
	return String::utf8(s.c_str());
}

std::string std_str(const String &s) {
	CharString c = s.utf8();
	return std::string(c.get_data(), (size_t)c.length());
}

Dictionary dict_of(const dawkit::PluginInfo &p) {
	Dictionary d;
	d["format"] = str(p.format);
	d["id"] = str(p.id);
	d["name"] = str(p.name);
	d["vendor"] = str(p.vendor);
	d["version"] = str(p.version);
	d["path"] = str(p.path);
	d["category"] = str(p.category);
	d["instrument"] = p.instrument;
	d["has_editor"] = p.has_editor;
	return d;
}

} // namespace

DawKitPlugin::DawKitPlugin() {
	alive().insert(this);
	merged.reserve(4096);
}

DawKitPlugin::~DawKitPlugin() {
	alive().erase(this);
	editor_close();
	if (plugin) {
		plugin->deactivate();
	}
}

// --- finding plugins --------------------------------------------------------------------------

bool DawKitPlugin::hosting_available() {
#ifdef DAWKIT_HOSTS_PLUGINS
	return true;
#else
	return false;
#endif
}

PackedStringArray DawKitPlugin::formats() {
	PackedStringArray out;
#ifdef DAWKIT_HOSTS_PLUGINS
	out.push_back("CLAP");
	out.push_back("VST3");
#endif
#ifdef DAWKIT_HOSTS_LV2
	out.push_back("LV2");
#endif
	return out;
}

PackedStringArray DawKitPlugin::default_paths(const String &format) {
	PackedStringArray out;
	for (const std::string &p : dawkit::default_paths(std_str(format))) {
		out.push_back(str(p));
	}
	return out;
}

PackedStringArray DawKitPlugin::find_files(const String &format, const PackedStringArray &dirs) {
	std::vector<std::string> d;
	for (int i = 0; i < dirs.size(); i++) {
		d.push_back(std_str(dirs[i]));
	}
	PackedStringArray out;
	for (const std::string &p : dawkit::find_plugin_files(std_str(format), d)) {
		out.push_back(str(p));
	}
	return out;
}

Array DawKitPlugin::scan_file(const String &format, const String &path) {
	Array out;
	std::string problem;
	std::vector<dawkit::PluginInfo> found;
	std::string f = std_str(format);
	if (f == "CLAP") {
		found = dawkit::scan_clap(std_str(path), problem);
	} else if (f == "VST3") {
		found = dawkit::scan_vst3(std_str(path), problem);
	} else if (f == "LV2") {
		found = dawkit::scan_lv2(problem);
	}
	for (const dawkit::PluginInfo &p : found) {
		out.push_back(dict_of(p));
	}
	return out;
}

void DawKitPlugin::pump() {
	dawkit::RunLoop::get().pump();
	// Copied: a plugin's own callback may free another.
	std::vector<DawKitPlugin *> all(alive().begin(), alive().end());
	for (DawKitPlugin *p : all) {
		if (alive().count(p)) {
			p->main_thread();
		}
	}
}

void DawKitPlugin::main_thread() {
	if (!plugin) {
		return;
	}
	plugin->main_thread();
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) {
		int w = 0, h = 0;
		if (plugin->take_editor_resize(w, h)) {
			editor->resize(w, h);
		}
		editor->pump();
	}
#endif
}

// --- one plugin -------------------------------------------------------------------------------

bool DawKitPlugin::load(const Dictionary &d) {
	editor_close();
	plugin.reset();
	dawkit::PluginInfo info;
	info.format = std_str(d.get("format", ""));
	info.id = std_str(d.get("id", ""));
	info.path = std_str(d.get("path", ""));
	info.name = std_str(d.get("name", ""));
	std::string why;
#ifdef DAWKIT_HOSTS_PLUGINS
	plugin = dawkit::load_plugin(info, why);
#else
	why = "plugins are not hosted on this system";
#endif
	problem = plugin ? String() : str(why);
	return plugin != nullptr;
}

Dictionary DawKitPlugin::info() const {
	return plugin ? dict_of(plugin->info()) : Dictionary();
}

bool DawKitPlugin::is_instrument() const {
	return plugin && plugin->info().instrument;
}

bool DawKitPlugin::activate(double rate, int block) {
	if (!plugin) {
		return false;
	}
	max_block = std::max(block, 32);
	bool ok = plugin->activate(rate, max_block);
	problem = ok ? String() : str(plugin->error());
	return ok;
}

void DawKitPlugin::deactivate() {
	if (plugin) {
		plugin->deactivate();
	}
}

bool DawKitPlugin::is_active() const {
	return plugin && plugin->is_active();
}

int DawKitPlugin::latency() const {
	return plugin ? plugin->latency() : 0;
}

int DawKitPlugin::tail() const {
	return plugin ? plugin->tail_samples() : 0;
}

int DawKitPlugin::input_channels() const {
	return plugin ? plugin->input_channels() : 0;
}

int DawKitPlugin::output_channels() const {
	return plugin ? plugin->output_channels() : 0;
}

int DawKitPlugin::param_count() const {
	return plugin ? plugin->param_count() : 0;
}

Dictionary DawKitPlugin::param_info(int i) const {
	Dictionary d;
	if (!plugin || i < 0 || i >= plugin->param_count()) {
		return d;
	}
	const dawkit::ParamInfo &p = plugin->param(i);
	d["name"] = str(p.name);
	d["unit"] = str(p.unit);
	d["min"] = p.min;
	d["max"] = p.max;
	d["default"] = p.def;
	d["steps"] = p.steps;
	d["automatable"] = p.automatable;
	d["hidden"] = p.hidden;
	d["read_only"] = p.read_only;
	d["bypass"] = p.bypass;
	return d;
}

double DawKitPlugin::get_param(int i) const {
	return plugin ? plugin->get_normalized(i) : 0.0;
}

void DawKitPlugin::set_param(int i, double v) {
	if (plugin) {
		plugin->set_normalized(i, v);
	}
}

String DawKitPlugin::param_text(int i, double v) {
	if (!plugin || i < 0 || i >= plugin->param_count()) {
		return String();
	}
	return str(plugin->param_text(i, v < 0.0 ? plugin->get_normalized(i) : v));
}

PackedInt32Array DawKitPlugin::take_changed() {
	PackedInt32Array out;
	if (plugin) {
		for (int i : plugin->take_changed()) {
			out.push_back(i);
		}
	}
	return out;
}

bool DawKitPlugin::take_params_changed() {
	return plugin && plugin->take_params_rescanned();
}

PackedByteArray DawKitPlugin::get_state() {
	PackedByteArray out;
	std::vector<uint8_t> bytes;
	if (plugin && plugin->get_state(bytes)) {
		out.resize((int64_t)bytes.size());
		if (!bytes.empty()) {
			std::memcpy(out.ptrw(), bytes.data(), bytes.size());
		}
	} else if (plugin) {
		problem = str(plugin->error());
	}
	return out;
}

bool DawKitPlugin::set_state(const PackedByteArray &state) {
	if (!plugin) {
		return false;
	}
	std::vector<uint8_t> bytes(state.ptr(), state.ptr() + state.size());
	bool ok = plugin->set_state(bytes);
	problem = ok ? String() : str(plugin->error());
	return ok;
}

void DawKitPlugin::live(const dawkit::Event &e) {
	std::lock_guard<std::mutex> hold(live_push);
	live_events.push(e);
}

void DawKitPlugin::note_on(int key, int velocity, int channel) {
	dawkit::Event e;
	e.kind = velocity > 0 ? dawkit::Event::NOTE_ON : dawkit::Event::NOTE_OFF;
	e.key = (uint8_t)std::clamp(key, 0, 127);
	e.channel = (uint8_t)std::clamp(channel, 0, 15);
	e.value = std::clamp(velocity, 0, 127) / 127.0;
	live(e);
}

void DawKitPlugin::note_off(int key, int channel) {
	dawkit::Event e;
	e.kind = dawkit::Event::NOTE_OFF;
	e.key = (uint8_t)std::clamp(key, 0, 127);
	e.channel = (uint8_t)std::clamp(channel, 0, 15);
	live(e);
}

void DawKitPlugin::control(int controller, int value, int channel) {
	dawkit::Event e;
	e.kind = dawkit::Event::CONTROL;
	e.key = (uint8_t)std::clamp(controller, 0, 127);
	e.channel = (uint8_t)std::clamp(channel, 0, 15);
	e.value = std::clamp(value, 0, 127) / 127.0;
	live(e);
}

void DawKitPlugin::pitch_bend(double amount, int channel) {
	dawkit::Event e;
	e.kind = dawkit::Event::PITCH_BEND;
	e.channel = (uint8_t)std::clamp(channel, 0, 15);
	e.value = std::clamp(amount, -1.0, 1.0);
	live(e);
}

void DawKitPlugin::all_notes_off() {
	for (int ch = 0; ch < 16; ch++) {
		dawkit::Event e;
		e.kind = dawkit::Event::ALL_NOTES_OFF;
		e.channel = (uint8_t)ch;
		live(e);
	}
}

void DawKitPlugin::run(const float *const *in, float *const *out, int frames, const dawkit::Event *events, int count,
		const dawkit::Transport &transport) {
	merged.clear();
	dawkit::Event e;
	while (merged.size() < merged.capacity() && live_events.pop(e)) {
		e.offset = 0;
		merged.push_back(e);
	}
	for (int i = 0; i < count && merged.size() < merged.capacity(); i++) {
		merged.push_back(events[i]);
	}
	plugin->process(in, out, frames, merged.data(), (int)merged.size(), transport);
	runs.fetch_add(1);
}

PackedVector2Array DawKitPlugin::process(const PackedVector2Array &input) {
	PackedVector2Array output;
	output.resize(input.size());
	if (!plugin || !plugin->is_active()) {
		return output;
	}
	int block = std::min(max_block, 512);
	std::vector<float> il(block), ir(block), ol(block), orr(block);
	dawkit::Transport t;
	t.rate = 48000.0;
	const Vector2 *src = input.ptr();
	Vector2 *dst = output.ptrw();
	for (int64_t at = 0; at < input.size(); at += block) {
		int n = (int)std::min<int64_t>(block, input.size() - at);
		for (int i = 0; i < n; i++) {
			il[i] = src[at + i].x;
			ir[i] = src[at + i].y;
		}
		const float *ins[2] = { il.data(), plugin->input_channels() > 1 ? ir.data() : il.data() };
		float *outs[2] = { ol.data(), orr.data() };
		if (plugin->input_channels() == 1) {
			for (int i = 0; i < n; i++) il[i] = 0.5f * (il[i] + ir[i]);
		}
		run(ins, outs, n, nullptr, 0, t);
		for (int i = 0; i < n; i++) {
			float r = plugin->output_channels() > 1 ? orr[i] : ol[i];
			dst[at + i] = Vector2(plugin->output_channels() > 0 ? ol[i] : 0.0f, plugin->output_channels() > 0 ? r : 0.0f);
		}
		t.frames += n;
	}
	return output;
}

// --- its window -------------------------------------------------------------------------------

bool DawKitPlugin::editor_supported() {
#ifdef DAWKIT_HOSTS_PLUGINS
	return plugin && dawkit::EditorWindow::available() && plugin->editor_supported();
#else
	return false;
#endif
}

bool DawKitPlugin::editor_open() {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (!plugin) {
		return false;
	}
	if (editor) {
		return true;
	}
	std::string why;
	if (!dawkit::EditorWindow::available(&why)) {
		problem = str(why);
		return false;
	}
	editor = std::make_unique<dawkit::EditorWindow>();
	if (!editor->create(640, 480, why)) {
		problem = str(why);
		editor.reset();
		return false;
	}
	int w = 0, h = 0;
	if (!plugin->editor_open(editor->window(), w, h)) {
		problem = str(plugin->error());
		editor.reset();
		return false;
	}
	if (w > 0 && h > 0) {
		editor->resize(w, h);
	}
	return true;
#else
	problem = "plugins have no windows on this system";
	return false;
#endif
}

void DawKitPlugin::editor_close() {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) {
		if (plugin) {
			plugin->editor_close();
		}
		editor.reset();
	}
#endif
	picture.unref();
}

bool DawKitPlugin::editor_is_open() const {
	return editor != nullptr;
}

bool DawKitPlugin::editor_capture() {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (!editor) {
		return false;
	}
	int w = 0, h = 0;
	bool same = false;
	if (!editor->capture(pixels, w, h, same) || same) {
		return false;
	}
	PackedByteArray data;
	data.resize((int64_t)pixels.size());
	std::memcpy(data.ptrw(), pixels.data(), pixels.size());
	if (picture.is_valid() && picture->get_width() == w && picture->get_height() == h) {
		picture->set_data(w, h, false, Image::FORMAT_RGBA8, data);
	} else {
		picture = Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, data);
	}
	return true;
#else
	return false;
#endif
}

Vector2i DawKitPlugin::editor_size() const {
	return picture.is_valid() ? Vector2i(picture->get_width(), picture->get_height()) : Vector2i();
}

void DawKitPlugin::editor_pointer_move(int x, int y) {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) editor->pointer_move(x, y);
#endif
}

void DawKitPlugin::editor_pointer_button(int x, int y, int button, bool down) {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) editor->pointer_button(x, y, button, down);
#endif
}

void DawKitPlugin::editor_wheel(int x, int y, int notches) {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) editor->wheel(x, y, notches);
#endif
}

void DawKitPlugin::editor_key(int keysym, bool down, int modifiers) {
#ifdef DAWKIT_HOSTS_PLUGINS
	if (editor) editor->key((unsigned long)keysym, down, (unsigned)modifiers);
#endif
}

void DawKitPlugin::_bind_methods() {
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("hosting_available"), &DawKitPlugin::hosting_available);
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("formats"), &DawKitPlugin::formats);
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("default_paths", "format"), &DawKitPlugin::default_paths);
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("find_files", "format", "dirs"), &DawKitPlugin::find_files);
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("scan_file", "format", "path"), &DawKitPlugin::scan_file);
	ClassDB::bind_static_method("DawKitPlugin", D_METHOD("pump"), &DawKitPlugin::pump);
	ClassDB::bind_method(D_METHOD("load", "info"), &DawKitPlugin::load);
	ClassDB::bind_method(D_METHOD("is_loaded"), &DawKitPlugin::is_loaded);
	ClassDB::bind_method(D_METHOD("info"), &DawKitPlugin::info);
	ClassDB::bind_method(D_METHOD("get_error"), &DawKitPlugin::get_error);
	ClassDB::bind_method(D_METHOD("is_instrument"), &DawKitPlugin::is_instrument);
	ClassDB::bind_method(D_METHOD("activate", "rate", "max_block"), &DawKitPlugin::activate, DEFVAL(4096));
	ClassDB::bind_method(D_METHOD("deactivate"), &DawKitPlugin::deactivate);
	ClassDB::bind_method(D_METHOD("is_active"), &DawKitPlugin::is_active);
	ClassDB::bind_method(D_METHOD("latency"), &DawKitPlugin::latency);
	ClassDB::bind_method(D_METHOD("tail"), &DawKitPlugin::tail);
	ClassDB::bind_method(D_METHOD("input_channels"), &DawKitPlugin::input_channels);
	ClassDB::bind_method(D_METHOD("output_channels"), &DawKitPlugin::output_channels);
	ClassDB::bind_method(D_METHOD("param_count"), &DawKitPlugin::param_count);
	ClassDB::bind_method(D_METHOD("param_info", "index"), &DawKitPlugin::param_info);
	ClassDB::bind_method(D_METHOD("get_param", "index"), &DawKitPlugin::get_param);
	ClassDB::bind_method(D_METHOD("set_param", "index", "normalized"), &DawKitPlugin::set_param);
	ClassDB::bind_method(D_METHOD("param_text", "index", "normalized"), &DawKitPlugin::param_text, DEFVAL(-1.0));
	ClassDB::bind_method(D_METHOD("take_changed"), &DawKitPlugin::take_changed);
	ClassDB::bind_method(D_METHOD("take_params_changed"), &DawKitPlugin::take_params_changed);
	ClassDB::bind_method(D_METHOD("get_state"), &DawKitPlugin::get_state);
	ClassDB::bind_method(D_METHOD("set_state", "state"), &DawKitPlugin::set_state);
	ClassDB::bind_method(D_METHOD("note_on", "key", "velocity", "channel"), &DawKitPlugin::note_on, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("note_off", "key", "channel"), &DawKitPlugin::note_off, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("control", "controller", "value", "channel"), &DawKitPlugin::control, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("pitch_bend", "amount", "channel"), &DawKitPlugin::pitch_bend, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("all_notes_off"), &DawKitPlugin::all_notes_off);
	ClassDB::bind_method(D_METHOD("process", "input"), &DawKitPlugin::process);
	ClassDB::bind_method(D_METHOD("blocks_run"), &DawKitPlugin::blocks_run);
	ClassDB::bind_method(D_METHOD("editor_supported"), &DawKitPlugin::editor_supported);
	ClassDB::bind_method(D_METHOD("editor_open"), &DawKitPlugin::editor_open);
	ClassDB::bind_method(D_METHOD("editor_close"), &DawKitPlugin::editor_close);
	ClassDB::bind_method(D_METHOD("editor_is_open"), &DawKitPlugin::editor_is_open);
	ClassDB::bind_method(D_METHOD("editor_capture"), &DawKitPlugin::editor_capture);
	ClassDB::bind_method(D_METHOD("editor_image"), &DawKitPlugin::editor_image);
	ClassDB::bind_method(D_METHOD("editor_size"), &DawKitPlugin::editor_size);
	ClassDB::bind_method(D_METHOD("editor_pointer_move", "x", "y"), &DawKitPlugin::editor_pointer_move);
	ClassDB::bind_method(D_METHOD("editor_pointer_button", "x", "y", "button", "down"),
			&DawKitPlugin::editor_pointer_button);
	ClassDB::bind_method(D_METHOD("editor_wheel", "x", "y", "notches"), &DawKitPlugin::editor_wheel);
	ClassDB::bind_method(D_METHOD("editor_key", "keysym", "down", "modifiers"), &DawKitPlugin::editor_key, DEFVAL(0));
}

// --- on a bus ---------------------------------------------------------------------------------

void DawKitPluginEffect::set_plugin(const Ref<DawKitPlugin> &p) {
	plugin = p;
}

Ref<AudioEffectInstance> DawKitPluginEffect::_instantiate() {
	Ref<DawKitPluginEffectInstance> i;
	i.instantiate();
	i->base = Ref<DawKitPluginEffect>(this);
	return i;
}

void DawKitPluginEffect::forget(const void *who) {
	if (runner == who) {
		runner = nullptr;
	}
}

void DawKitPluginEffect::mix(const void *who, const AudioFrame *src, AudioFrame *dst, int frames) {
	DawKitPlugin *p = plugin.ptr();
	if (bypass.load() || !p || !p->is_active() || p->max_block_size() <= 0) {
		for (int i = 0; i < frames; i++) dst[i] = src[i];
		return;
	}
	int64_t clock = transport.is_valid() ? transport->get_clock() : INT64_MIN;
	// The first of the buses in a block runs the plugin. Without a clock, the one that ran it last
	// time runs it again: the next block has begun.
	bool fresh = runner == nullptr || who == runner || clock != last_clock;
	if (!fresh && (int)made.size() == frames) {
		for (int i = 0; i < frames; i++) dst[i] = made[i];
		return;
	}
	runner = who;
	last_clock = clock;
	dawkit::Transport t;
	if (transport.is_valid()) {
		transport->describe(clock - frames, t);
	}
	dawkit::HostedPlugin *h = p->hosted();
	int ins = h->input_channels(), outs = h->output_channels();
	int block = p->max_block_size();
	if ((int)in_l.size() < block) {
		// Once, the first time; the plugin's block size does not change while it is active.
		in_l.assign(block, 0.0f);
		in_r.assign(block, 0.0f);
		out_l.assign(block, 0.0f);
		out_r.assign(block, 0.0f);
	}
	if ((int)made.capacity() < frames) {
		made.reserve(std::max(frames, 4096));
	}
	made.resize(frames);
	for (int at = 0; at < frames; at += block) {
		int n = std::min(block, frames - at);
		for (int i = 0; i < n; i++) {
			in_l[i] = src[at + i].left;
			in_r[i] = src[at + i].right;
			if (ins == 1) in_l[i] = 0.5f * (in_l[i] + in_r[i]);
		}
		const float *in[2] = { in_l.data(), in_r.data() };
		float *out[2] = { out_l.data(), out_r.data() };
		p->run(in, out, n, nullptr, 0, t);
		for (int i = 0; i < n; i++) {
			AudioFrame f;
			f.left = outs > 0 ? out_l[i] : 0.0f;
			f.right = outs > 1 ? out_r[i] : f.left;
			dst[at + i] = f;
			made[at + i] = f;
		}
	}
}

PackedVector2Array DawKitPluginEffect::process_as(int bus, const PackedVector2Array &input) {
	std::vector<AudioFrame> src(input.size()), dst(input.size());
	for (int64_t i = 0; i < input.size(); i++) {
		src[i].left = input[i].x;
		src[i].right = input[i].y;
	}
	// Any address stands for an instance: only its identity is used.
	static char buses[64];
	mix(&buses[std::clamp(bus, 0, 63)], src.data(), dst.data(), (int)input.size());
	PackedVector2Array out;
	out.resize(input.size());
	for (int64_t i = 0; i < input.size(); i++) {
		out[i] = Vector2(dst[i].left, dst[i].right);
	}
	return out;
}

void DawKitPluginEffect::_bind_methods() {
	ClassDB::bind_method(D_METHOD("process_as", "bus", "input"), &DawKitPluginEffect::process_as);
	ClassDB::bind_method(D_METHOD("set_plugin", "plugin"), &DawKitPluginEffect::set_plugin);
	ClassDB::bind_method(D_METHOD("get_plugin"), &DawKitPluginEffect::get_plugin);
	ClassDB::bind_method(D_METHOD("set_transport", "transport"), &DawKitPluginEffect::set_transport);
	ClassDB::bind_method(D_METHOD("get_transport"), &DawKitPluginEffect::get_transport);
	ClassDB::bind_method(D_METHOD("set_bypass", "bypass"), &DawKitPluginEffect::set_bypass);
	ClassDB::bind_method(D_METHOD("get_bypass"), &DawKitPluginEffect::get_bypass);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "plugin", PROPERTY_HINT_RESOURCE_TYPE, "DawKitPlugin",
						 PROPERTY_USAGE_NONE),
			"set_plugin", "get_plugin");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "bypass"), "set_bypass", "get_bypass");
}

DawKitPluginEffectInstance::~DawKitPluginEffectInstance() {
	if (base.is_valid()) {
		base->forget(this);
	}
}

void DawKitPluginEffectInstance::_process(const void *src, AudioFrame *dst, int32_t frames) {
	if (base.is_null()) {
		for (int i = 0; i < frames; i++) dst[i] = ((const AudioFrame *)src)[i];
		return;
	}
	base->mix(this, (const AudioFrame *)src, dst, frames);
}
