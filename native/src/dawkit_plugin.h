#pragma once

#include "dawkit_transport.h"
#include "plugins/hosted_plugin.h"

#include <godot_cpp/classes/audio_effect.hpp>
#include <godot_cpp/classes/audio_effect_instance.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace dawkit {
class EditorWindow;
}

namespace godot {

// A third-party plugin (CLAP, VST3 or LV2), loaded into the engine.
//
// One instance of the plugin, shared by whatever plays through it: a DawKitPluginEffect on a
// track's bus for an effect, a DawKitLane for an instrument. Everything here is the main thread's
// but `run`, which is the mixer's.
//
// Plugins are found with `scan_file` (in this process, so a plugin that crashes as it is looked at
// takes the engine with it) or the `dawkit_scan` program beside the extension, which does the same
// in a process of its own and prints what it found as JSON.
class DawKitPlugin : public RefCounted {
	GDCLASS(DawKitPlugin, RefCounted)

public:
	DawKitPlugin();
	~DawKitPlugin() override;

	// --- finding plugins ----------------------------------------------------------------------
	// Whether this system can host plugins at all, and which formats.
	static bool hosting_available();
	static PackedStringArray formats();
	static PackedStringArray default_paths(const String &format);
	static PackedStringArray find_files(const String &format, const PackedStringArray &dirs);
	// Every plugin in one file or bundle, each as `info()` describes one: {format, id, name,
	// vendor, version, path, category, instrument, has_editor}. For LV2 the path is ignored and
	// every installed plugin is listed. Runs the plugin's code.
	static Array scan_file(const String &format, const String &path);
	// Once a frame, from the main thread: plugins' timers, the windows they asked for, what they
	// asked to be done on the main thread, and their windows' sizes.
	static void pump();

	// --- one plugin ---------------------------------------------------------------------------
	// `info` as a scan gave it: format, id and path at least.
	bool load(const Dictionary &info);
	bool is_loaded() const { return plugin != nullptr; }
	// Loads it on a thread of its own, set from `state` (if any) and active at `rate`: the main
	// thread carries on meanwhile, and `is_loading` says when it is done (`is_loaded`, or
	// `get_error` says why not). While it loads the plugin is not yet here -- nothing is run, pumped
	// or shown -- but `info`, `is_instrument` and `get_state` answer as it was asked for, so a slot
	// holding it can be named and saved. False when a load is already under way.
	bool begin_load(const Dictionary &info, const PackedByteArray &state, double rate, int max_block);
	// Whether it is still loading. From the main thread, which takes the plugin over once it is done.
	bool is_loading();
	// Waits for a load under way to end, on the main thread. Whether the plugin is loaded.
	bool wait_loaded();
	// Something that went wrong in a load that still loaded it (its saved state not taken), or "".
	String get_warning() const { return warning; }
	// Whether any plugin is loading now.
	static bool loads_running();
	// The titles of windows plugins' processes opened on the desktop and that were left there to be
	// answered (an activation, a licence, a file to open), since last asked. Everything else a
	// plugin puts up is kept off the desktop (see plugins/x11_editor.cpp).
	static PackedStringArray take_desktop_windows();
	// The parameters worth putting in front of someone, in the plugin's order: not hidden, not read
	// only, automatable (or, for a plugin that marks none automatable, every one not hidden), at most
	// `limit`. In C++ because a VST3 lists two thousand MIDI controller slots after its real controls.
	PackedInt32Array shown_params(int limit) const;
	Dictionary info() const;
	String get_error() const { return problem; }
	bool is_instrument() const;

	bool activate(double rate, int max_block);
	void deactivate();
	bool is_active() const;
	int latency() const;
	int tail() const;
	int input_channels() const;
	int output_channels() const;

	int param_count() const;
	// {name, unit, min, max, default (normalised), steps, automatable, hidden, read_only, bypass}
	Dictionary param_info(int index) const;
	double get_param(int index) const;
	void set_param(int index, double normalized);
	// The plugin's own words for a value of the parameter, or for its value now (below 0).
	String param_text(int index, double normalized = -1.0);
	// The parameters the plugin moved of itself since last asked: its window, a preset.
	PackedInt32Array take_changed();
	// The plugin's parameters are not the ones they were (names, how many): read them again.
	bool take_params_changed();

	PackedByteArray get_state();
	bool set_state(const PackedByteArray &state);

	// Played on the plugin's next block, from the main thread: notes for an instrument heard live.
	void note_on(int key, int velocity, int channel = 0);
	void note_off(int key, int channel = 0);
	void control(int controller, int value, int channel = 0);
	void pitch_bend(double amount, int channel = 0);
	void all_notes_off();

	// `input` through the plugin, block by block: for tests and offline work, never while the
	// plugin is on a bus. Stereo in, stereo out.
	PackedVector2Array process(const PackedVector2Array &input);

	// --- its window ---------------------------------------------------------------------------
	bool editor_supported();
	// Opens it. A yabridge plugin's (HostedPlugin::is_bridged) is opened on a thread of its own --
	// seconds, while yabridge's Wine host makes it -- and is open (`editor_is_open`) but
	// `editor_opening` until that is done, with nothing to capture yet; one that then fails is
	// closed again, with `get_error` saying why. Every other plugin's opens here, on the main thread,
	// as its toolkit wants: it makes X windows of its own, on a connection of its own, which it then
	// works from the thread it was made on (JUCE's and iPlug's take that thread for their message
	// thread), and that must be the one that pumps it.
	bool editor_open();
	void editor_close();
	bool editor_is_open() const;
	bool editor_opening() const { return opening != nullptr; }
	// Takes a new picture of the window: true when it changed since the last.
	bool editor_capture();
	Ref<Image> editor_image() const { return picture; }
	Vector2i editor_size() const;
	void editor_pointer_move(int x, int y);
	void editor_pointer_button(int x, int y, int button, bool down);
	void editor_wheel(int x, int y, int notches);
	void editor_key(int keysym, bool down, int modifiers = 0);

	// --- the mixer's --------------------------------------------------------------------------
	// Through the plugin, with the notes played live since the last block before `events`.
	void run(const float *const *in, float *const *out, int frames, const dawkit::Event *events, int count,
			const dawkit::Transport &transport);
	int max_block_size() const { return max_block; }
	// How many blocks the plugin has been run for: a check that a shared one runs once a block.
	int64_t blocks_run() const { return runs.load(); }
	dawkit::HostedPlugin *hosted() const { return plugin.get(); }

protected:
	static void _bind_methods();

private:
	void live(const dawkit::Event &e);
	void main_thread();
	void take_over_load();
	struct Loading;
	static void load_job(Loading *job, bool own_thread);

	// A load on a thread of its own, and what it made. The thread writes `made`, `why` and `warning`
	// and then `done`; the main thread reads them only once `done` is set.
	struct Loading {
		std::thread worker;
		std::atomic<bool> done{ false };
		std::atomic<bool> cancelled{ false }; // let go of before its turn came: never made
		int owner = 0;
		dawkit::PluginInfo asked;
		std::vector<uint8_t> state;
		double rate = 48000.0;
		int max_block = 1024;
		std::unique_ptr<dawkit::HostedPlugin> made;
		std::string why;
		std::string warning;
	};
	std::unique_ptr<Loading> loading;
	String warning;

	// The plugin's window being opened on a thread of its own. The thread writes `ok`, `width`,
	// `height` and `why`, then `done`; the main thread reads them only once `done` is set, and keeps
	// `cancelled` (closed before it was done) to itself.
	struct Opening {
		std::thread worker;
		std::atomic<bool> done{ false };
		bool cancelled = false;
		int owner = 0;
		bool ok = false;
		int width = 0, height = 0;
		std::string why;
	};
	std::unique_ptr<Opening> opening;
	// Takes over an opening that is done (all of it, waiting, when `wait`). Whether one is still under way.
	bool take_over_opening(bool wait);

	std::unique_ptr<dawkit::HostedPlugin> plugin;
	String problem;
	int max_block = 0;
	std::atomic<int64_t> runs{ 0 };
	dawkit::Ring<dawkit::Event, 2048> live_events;
	std::mutex live_push;
	std::vector<dawkit::Event> merged;
	std::unique_ptr<dawkit::EditorWindow> editor;
	Ref<Image> picture;
	std::vector<uint8_t> pixels;
};

// A plugin effect on a bus. The same effect on several buses (a track's, its sends', its cue's,
// which all play the same lane) runs the plugin once a block, and the rest hear what it made.
class DawKitPluginEffect : public AudioEffect {
	GDCLASS(DawKitPluginEffect, AudioEffect)

public:
	void set_plugin(const Ref<DawKitPlugin> &p);
	Ref<DawKitPlugin> get_plugin() const { return plugin; }
	// The song's clock: what tells one block from the next, and where the plugin is told the
	// song is.
	void set_transport(const Ref<DawKitTransport> &t) { transport = t; }
	Ref<DawKitTransport> get_transport() const { return transport; }
	void set_bypass(bool b) { bypass.store(b); }
	bool get_bypass() const { return bypass.load(); }

	Ref<AudioEffectInstance> _instantiate() override;

	void mix(const void *who, const AudioFrame *src, AudioFrame *dst, int frames);
	// `input` through the effect as the bus numbered `bus` would put it through, for checks: the
	// server mixes nothing headless.
	PackedVector2Array process_as(int bus, const PackedVector2Array &input);
	void forget(const void *who);

protected:
	static void _bind_methods();

private:
	Ref<DawKitPlugin> plugin;
	Ref<DawKitTransport> transport;
	std::atomic<bool> bypass{ false };
	// The mixer's.
	const void *runner = nullptr;
	int64_t last_clock = INT64_MIN;
	std::vector<AudioFrame> made;
	std::vector<float> in_l, in_r, out_l, out_r;
};

class DawKitPluginEffectInstance : public AudioEffectInstance {
	GDCLASS(DawKitPluginEffectInstance, AudioEffectInstance)

public:
	~DawKitPluginEffectInstance() override;
	Ref<DawKitPluginEffect> base;
	void _process(const void *src, AudioFrame *dst, int32_t frames) override;
	bool _process_silence() const override { return true; }

protected:
	static void _bind_methods() {}
};

} // namespace godot
