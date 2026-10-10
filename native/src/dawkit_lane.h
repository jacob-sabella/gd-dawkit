#pragma once

#include "dawkit_transport.h"

#include <godot_cpp/classes/audio_stream.hpp>
#include <godot_cpp/classes/audio_stream_playback.hpp>
#include <godot_cpp/classes/audio_stream_wav.hpp>

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
		int fade_shape = 0; // 0 linear, 1 equal power
		double loop_start = 0.0; // seconds of the sound looped, both 0 for none
		double loop_end = 0.0;
	};
	using Clips = std::vector<Clip>;

	void set_transport(const Ref<DawKitTransport> &p_transport) { transport = p_transport; }
	Ref<DawKitTransport> get_transport() const { return transport; }
	// The clips, replacing the last: each {id, samples (PackedFloat32Array), channels, rate,
	// start, length, offset (seconds), gain (linear), fade_in, fade_out (seconds), fade_shape,
	// loop_start, loop_end}. A sound already given under the same id is not copied again.
	void set_clips(const Array &clips);
	int clip_count() const;
	// Whether the transport's hold (a count-in) silences this lane. The click is not held.
	void set_held(bool p_held) { held.store(p_held); }
	bool get_held() const { return held.load(); }

	std::shared_ptr<const Clips> snapshot() const { return std::atomic_load(&clips); }

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
