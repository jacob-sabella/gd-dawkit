#pragma once

#include "dawkit_plugin.h"
#include "dawkit_transport.h"

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/audio_stream_wav.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

#include <memory>
#include <unordered_map>
#include <vector>

namespace godot {

// A track's sound for the song: its clips, each where it sits in the song, played sample for
// sample wherever the shared transport says the song is. One playback per track, always playing,
// on the track's own bus, so the bus's fader, effects and sends work on it as on any stream.
class DawKitLane : public AudioStream {
	GDCLASS(DawKitLane, AudioStream)

public:
	struct Sound {
		std::vector<float> samples; // stereo, interleaved
		int rate = 48000;
		int64_t frames = 0;
	};
	struct Clip {
		std::shared_ptr<const Sound> sound;
		int64_t start = 0; // song frame, at the transport's rate
		int64_t length = 0; // song frames
		double offset = 0.0; // seconds into the sound at the clip's start
		float gain = 1.0f;
		int64_t fade_in = 0; // song frames
		int64_t fade_out = 0;
		int fade_shape = 0; // the fade in's: DawKitClip's FADE_ shapes, 0 linear .. 4 S-curve
		int fade_out_shape = 0;
		double loop_start = 0.0; // seconds of the sound looped, both 0 for none
		double loop_end = 0.0;
	};
	using Clips = std::vector<Clip>;

	void set_transport(const Ref<DawKitTransport> &p_transport) { transport = p_transport; }
	Ref<DawKitTransport> get_transport() const { return transport; }
	// The clips, replacing the last: each {id, samples (PackedFloat32Array), channels, rate,
	// start, length, offset (seconds), gain (linear), fade_in, fade_out (seconds), fade_shape,
	// fade_out_shape (fade_shape when not given), loop_start, loop_end}. A sound already given under the same id is not copied again.
	void set_clips(const Array &clips);
	int clip_count() const;
	// Whether the transport's hold (a count-in) silences this lane. The click is not held.
	void set_held(bool p_held) { held.store(p_held); }
	bool get_held() const { return held.load(); }

	std::shared_ptr<const Clips> snapshot() const { return std::atomic_load(&clips); }

	// An instrument plugin the lane plays its notes through, beside its clips, and anything played
	// on the plugin live (DawKitPlugin.note_on). Null for none.
	void set_instrument(const Ref<DawKitPlugin> &p_plugin);
	Ref<DawKitPlugin> get_instrument() const { return instrument_ref; }
	// The notes for it, replacing the last: flat, five numbers a note -- start and end in song
	// seconds, key, velocity (1-127), channel (0-15).
	void set_notes(const PackedFloat64Array &notes);
	int note_count() const;

	struct Note {
		int64_t start, end;
		uint8_t key, velocity, channel;
	};
	struct Instrument {
		Ref<DawKitPlugin> plugin;
		std::vector<Note> notes; // by start
	};
	// The instrument's sound for the block starting at clock frame `block`, added into `buffer`:
	// made by the first playback to ask, and the same for the rest.
	void mix_instrument(int64_t block, AudioFrame *buffer, int32_t frames);

	Ref<AudioStreamPlayback> _instantiate_playback() const override;
	String _get_stream_name() const override { return "DawKitLane"; }
	double _get_length() const override { return 0.0; }
	bool _is_monophonic() const override { return true; }

protected:
	static void _bind_methods();

private:
	Ref<DawKitTransport> transport;
	std::atomic<bool> held{ true };
	std::shared_ptr<const Clips> clips = std::make_shared<Clips>();
	std::unordered_map<int64_t, std::shared_ptr<const Sound>> sounds;

	void publish(std::shared_ptr<const Instrument> next);
	Ref<DawKitPlugin> instrument_ref;
	std::vector<Note> pending_notes;
	std::shared_ptr<const Instrument> instrument;
	// Let go of on the main thread, once the mixer has, so a plugin is never freed in the mixer.
	std::vector<std::shared_ptr<const Instrument>> retired;

	// The mixer's.
	struct Sounding {
		uint8_t key, channel;
		int64_t end;
	};
	int64_t made_block = INT64_MIN;
	std::vector<float> made_l, made_r, silence;
	std::vector<Sounding> sounding;
	std::vector<dawkit::Event> events;
	int64_t last_song = DawKitTransport::NOT_PLAYING;
};

class DawKitLanePlayback : public AudioStreamPlayback {
	GDCLASS(DawKitLanePlayback, AudioStreamPlayback)

public:
	Ref<DawKitLane> lane;
	int64_t seen = 0;

	void _start(double from_pos) override {}
	void _stop() override {}
	bool _is_playing() const override { return true; }
	int32_t _mix(AudioFrame *buffer, float rate_scale, int32_t frames) override;

protected:
	static void _bind_methods() {}
};

} // namespace godot
