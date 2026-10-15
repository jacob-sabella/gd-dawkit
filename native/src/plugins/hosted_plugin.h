#pragma once

// Third-party plugins (CLAP, VST3, LV2) hosted by the engine: one interface over the three formats.
//
// Plain C++, nothing of Godot's, so the out-of-process scanner (dawkit_scan.cpp) uses the same code
// the engine does. The Godot classes (DawKitPlugin, DawKitPluginEffect, DawKitLane's instrument)
// wrap a HostedPlugin.
//
// Threads. A plugin has two: the main thread (Godot's), which creates it, reads and sets its
// parameters, saves its state and runs its window; and the audio thread (Godot's mixer), which only
// ever calls `process`. Whatever crosses between them goes through lock-free queues and atomics
// here, never a lock the audio thread could wait on.

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace dawkit {

// What a plugin is, as a scan finds it, before it is loaded.
struct PluginInfo {
	std::string format; // "CLAP", "VST3", "LV2"
	std::string id; // CLAP's id, VST3's class id (32 hex digits), LV2's URI
	std::string name;
	std::string vendor;
	std::string version;
	std::string path; // the file or bundle it is loaded from
	std::string category; // the plugin's own words: "Fx|Distortion", "instrument synthesizer"
	bool instrument = false;
	bool has_editor = false; // as far as a scan can tell without opening it
};

// One parameter. Its value is normalised 0..1 everywhere outside the format's own code; `min`,
// `max` and `steps` say what 0..1 stands for.
struct ParamInfo {
	std::string name;
	std::string unit;
	double min = 0.0;
	double max = 1.0;
	double def = 0.0; // normalised
	int steps = 0; // 0 continuous, else how many steps between min and max
	bool automatable = true;
	bool hidden = false;
	bool read_only = false;
	bool bypass = false;
	bool logarithmic = false;
	uint32_t format_id = 0; // the format's own handle: CLAP's param id, VST3's ParamID, LV2's port
};

// Something for the plugin at a sample of the block.
struct Event {
	enum Kind : uint8_t { NOTE_ON, NOTE_OFF, CONTROL, PITCH_BEND, ALL_NOTES_OFF };
	Kind kind = NOTE_ON;
	uint8_t channel = 0;
	uint8_t key = 0; // the note, or the controller
	int32_t offset = 0; // sample in the block
	double value = 0.0; // velocity 0..1, a controller 0..1, a bend -1..1
};

// Where the song is, for a plugin that keeps time with it (a synced delay, an arpeggiator).
struct Transport {
	bool playing = false;
	double seconds = 0.0;
	double beats = 0.0; // quarter notes from the song's start
	double bar_start = 0.0; // in quarter notes
	double tempo = 120.0;
	int numerator = 4;
	int denominator = 4;
	double rate = 48000.0;
	int64_t frames = 0; // samples processed since the plugin started, for CLAP's steady time
};

// A single-producer, single-consumer queue that never blocks or allocates once made.
template <typename T, size_t N>
class Ring {
public:
	bool push(const T &v) {
		size_t w = write.load(std::memory_order_relaxed);
		size_t next = (w + 1) % N;
		if (next == read.load(std::memory_order_acquire)) {
			return false;
		}
		items[w] = v;
		write.store(next, std::memory_order_release);
		return true;
	}
	bool pop(T &v) {
		size_t r = read.load(std::memory_order_relaxed);
		if (r == write.load(std::memory_order_acquire)) {
			return false;
		}
		v = items[r];
		read.store((r + 1) % N, std::memory_order_release);
		return true;
	}
	void clear() {
		T v;
		while (pop(v)) {
		}
	}

private:
	T items[N];
	std::atomic<size_t> write{ 0 };
	std::atomic<size_t> read{ 0 };
};

// The main thread's loop for plugins that want one: file descriptors to watch and timers to run,
// which Linux plugin windows ask their host for (VST3's IRunLoop, CLAP's posix-fd and timer
// extensions). `pump` runs it, once a frame, from the main thread.
class RunLoop {
public:
	using Callback = std::function<void()>;
	static RunLoop &get();
	// Returns an id to remove it by.
	int add_fd(int fd, Callback on_ready);
	int add_timer(int period_ms, Callback on_tick);
	void remove(int id);
	void pump();

private:
	struct Entry {
		int id;
		int fd; // -1 for a timer
		int period_ms;
		double due;
		Callback call;
		bool gone = false;
	};
	std::vector<Entry> entries;
	int next_id = 1;
	bool pumping = false;
};

// Whether this is the thread plugins are made on.
bool on_main_thread();
void set_main_thread();

// Seconds on a steady clock.
double now_seconds();

class HostedPlugin {
public:
	virtual ~HostedPlugin() = default;

	const PluginInfo &info() const { return description; }
	// Why the last thing asked of it did not happen, in a sentence.
	const std::string &error() const { return problem; }

	// --- the main thread ----------------------------------------------------------------------
	virtual bool activate(double rate, int max_block) = 0;
	virtual void deactivate() = 0;
	bool is_active() const { return active.load(); }

	int param_count() const { return (int)params.size(); }
	const ParamInfo &param(int i) const { return params[i]; }
	// The parameter's value as last known, normalised. Safe from any thread.
	double get_normalized(int i) const;
	// Sets it, from the main thread: in the plugin by its next block, and in its window.
	virtual void set_normalized(int i, double value) = 0;
	// What the plugin calls `value` of parameter `i`, in its own words ("-6.0 dB").
	virtual std::string param_text(int i, double value) = 0;
	// The parameters the plugin changed of itself since last asked (its window, a preset).
	std::vector<int> take_changed();
	// The plugin re-described its parameters (names, how many): read them again.
	bool take_params_rescanned() { return rescanned.exchange(false); }

	virtual bool get_state(std::vector<uint8_t> &out) = 0;
	virtual bool set_state(const std::vector<uint8_t> &in) = 0;

	virtual int latency() const { return 0; }
	virtual int tail_samples() const { return 0; }
	int input_channels() const { return inputs; }
	int output_channels() const { return outputs; }

	// Whatever the plugin asked to be done on the main thread, done. Once a frame.
	virtual void main_thread() {}

	// Its own window, embedded in `parent` (an X11 window). False when it has none or it failed.
	virtual bool editor_supported() = 0;
	virtual bool editor_open(unsigned long parent, int &width, int &height) = 0;
	virtual void editor_close() = 0;
	// The size it last asked to be, when it asked since this was last called.
	bool take_editor_resize(int &width, int &height);

	// --- the audio thread ---------------------------------------------------------------------
	// `frames` of `in` (inputs channels, planar) through the plugin into `out` (outputs channels).
	// `events` are sorted by offset. Parameters set since the last block are applied at its start.
	virtual void process(const float *const *in, float *const *out, int frames, const Event *events,
			int event_count, const Transport &transport) = 0;

protected:
	// Called by the format's code when the plugin's parameters are known (again).
	void set_params(std::vector<ParamInfo> list);
	// The value of `i` changed, normalised; from the plugin (`by_plugin`) or from the host.
	void store_value(int i, double value, bool by_plugin);
	void request_editor_size(int width, int height);
	void mark_rescanned() { rescanned.store(true); }

	struct ParamChange {
		int index;
		double value;
	};
	// Set on the main thread (or a plugin window's own), applied by the audio thread at the start of
	// its next block. Only the pushing side locks: the audio thread never waits.
	Ring<ParamChange, 4096> to_audio;
	void queue_to_audio(int index, double value) {
		std::lock_guard<std::mutex> hold(pushing);
		to_audio.push({ index, value });
	}
	std::mutex pushing;

	PluginInfo description;
	std::string problem;
	std::vector<ParamInfo> params;
	std::unique_ptr<std::atomic<double>[]> values;
	std::unique_ptr<std::atomic<bool>[]> changed;
	std::atomic<bool> any_changed{ false };
	std::atomic<bool> rescanned{ false };
	std::atomic<bool> active{ false };
	std::atomic<int> resize_w{ 0 };
	std::atomic<int> resize_h{ 0 };
	std::atomic<bool> resized{ false };
	int inputs = 2;
	int outputs = 2;
};

// Finding plugins. Each returns what is in one file or bundle; nothing found is an empty list and
// `problem` says why. Loading a plugin to scan it runs its code, which can crash: the engine scans
// out of process (dawkit_scan), and these are what that process calls.
std::vector<PluginInfo> scan_clap(const std::string &path, std::string &problem);
std::vector<PluginInfo> scan_vst3(const std::string &path, std::string &problem);
std::vector<PluginInfo> scan_lv2(std::string &problem); // every LV2 plugin lilv finds
// Where a format's plugins are installed on this system, by its own convention.
std::vector<std::string> default_paths(const std::string &format);
// Every file or bundle of `format` under `dirs`, recursively.
std::vector<std::string> find_plugin_files(const std::string &format, const std::vector<std::string> &dirs);

// One loaded, not yet active. Null with `problem` set when it would not load.
std::unique_ptr<HostedPlugin> load_clap(const std::string &path, const std::string &id, std::string &problem);
std::unique_ptr<HostedPlugin> load_vst3(const std::string &path, const std::string &id, std::string &problem);
std::unique_ptr<HostedPlugin> load_lv2(const std::string &uri, std::string &problem);
std::unique_ptr<HostedPlugin> load_plugin(const PluginInfo &info, std::string &problem);

} // namespace dawkit
