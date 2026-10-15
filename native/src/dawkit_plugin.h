#pragma once

#include "dawkit_transport.h"
#include "plugins/hosted_plugin.h"

#include <godot_cpp/classes/audio_effect.hpp>
#include <godot_cpp/classes/audio_effect_instance.hpp>
#include <godot_cpp/classes/audio_frame.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <memory>
#include <mutex>
#include <vector>

namespace dawkit {
class X11Editor;
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
	bool editor_open();
	void editor_close();
	bool editor_is_open() const;
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

	std::unique_ptr<dawkit::HostedPlugin> plugin;
	String problem;
	int max_block = 0;
	std::atomic<int64_t> runs{ 0 };
	dawkit::Ring<dawkit::Event, 2048> live_events;
	std::mutex live_push;
	std::vector<dawkit::Event> merged;
	std::unique_ptr<dawkit::X11Editor> editor;
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
