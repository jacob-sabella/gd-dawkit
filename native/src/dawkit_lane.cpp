#include "dawkit_lane.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

void DawKitLane::set_clips(const Array &given) {
	int rate = transport.is_valid() ? transport->get_rate() : 48000;
	auto out = std::make_shared<Clips>();
	std::unordered_map<int64_t, std::shared_ptr<const Sound>> kept;
	for (int i = 0; i < given.size(); i++) {
		Dictionary d = given[i];
		int64_t id = d.get("id", (int64_t)-1);
		std::shared_ptr<const Sound> sound;
		auto had = sounds.find(id);
		if (id >= 0 && had != sounds.end()) {
			sound = had->second;
		} else {
			PackedFloat32Array samples = d.get("samples", PackedFloat32Array());
			int channels = std::max((int)d.get("channels", 2), 1);
			auto s = std::make_shared<Sound>();
			s->rate = std::max((int)d.get("rate", 48000), 1);
			s->frames = samples.size() / channels;
			s->samples.resize(s->frames * 2);
			const float *src = samples.ptr();
			for (int64_t f = 0; f < s->frames; f++) {
				float l = src[f * channels];
				float r = channels > 1 ? src[f * channels + 1] : l;
				s->samples[f * 2] = l;
				s->samples[f * 2 + 1] = r;
			}
			sound = s;
		}
		if (id >= 0) {
			kept[id] = sound;
		}
		Clip c;
		c.sound = sound;
		c.start = (int64_t)std::llround((double)d.get("start", 0.0) * rate);
		c.length = (int64_t)std::llround((double)d.get("length", 0.0) * rate);
		c.offset = d.get("offset", 0.0);
		c.gain = (float)(double)d.get("gain", 1.0);
		c.fade_in = (int64_t)std::llround((double)d.get("fade_in", 0.0) * rate);
		c.fade_out = (int64_t)std::llround((double)d.get("fade_out", 0.0) * rate);
		c.fade_shape = d.get("fade_shape", 0);
		c.loop_start = d.get("loop_start", 0.0);
		c.loop_end = d.get("loop_end", 0.0);
		if (c.length > 0 && sound->frames > 0) {
			out->push_back(c);
		}
	}
	sounds.swap(kept);
	std::atomic_store(&clips, std::shared_ptr<const Clips>(out));
}

int DawKitLane::clip_count() const {
	return (int)snapshot()->size();
}

Ref<AudioStreamPlayback> DawKitLane::_instantiate_playback() const {
	Ref<DawKitLanePlayback> p;
	p.instantiate();
	p->lane = Ref<DawKitLane>(const_cast<DawKitLane *>(this));
	if (transport.is_valid()) {
		p->seen = transport->get_clock();
	}
	return p;
}

void DawKitLane::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_transport", "transport"), &DawKitLane::set_transport);
	ClassDB::bind_method(D_METHOD("get_transport"), &DawKitLane::get_transport);
	ClassDB::bind_method(D_METHOD("set_clips", "clips"), &DawKitLane::set_clips);
	ClassDB::bind_method(D_METHOD("clip_count"), &DawKitLane::clip_count);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "transport", PROPERTY_HINT_RESOURCE_TYPE, "DawKitTransport"),
			"set_transport", "get_transport");
}

// How loud a fade is `t` (0-1) of the way in.
static inline float fade_gain(double t, int shape) {
	t = std::clamp(t, 0.0, 1.0);
	return shape == 1 ? (float)std::sin(t * 1.5707963267948966) : (float)t;
}

int32_t DawKitLanePlayback::_mix(AudioFrame *buffer, float rate_scale, int32_t frames) {
	for (int32_t i = 0; i < frames; i++) {
		buffer[i].left = 0.0f;
		buffer[i].right = 0.0f;
	}
	if (lane.is_null() || lane->get_transport().is_null()) {
		return frames;
	}
	Ref<DawKitTransport> t = lane->get_transport();
	int64_t block = t->claim_block(seen, frames);
	if (!t->is_playing()) {
		return frames;
	}
	std::shared_ptr<const DawKitLane::Clips> clips = lane->snapshot();
	const double rate = t->get_rate();
	for (int32_t i = 0; i < frames; i++) {
		int64_t song = t->song_frame_at(block + i);
		if (song < 0) {
			continue;
		}
		float l = 0.0f, r = 0.0f;
		for (const DawKitLane::Clip &c : *clips) {
			int64_t into = song - c.start;
			if (into < 0 || into >= c.length) {
				continue;
			}
			const DawKitLane::Sound &s = *c.sound;
			// Where in the sound, in its own frames, at its own rate.
			double at = c.offset + (double)into / rate;
			if (c.loop_end > c.loop_start && at >= c.loop_end) {
				at = c.loop_start + std::fmod(at - c.loop_start, c.loop_end - c.loop_start);
			}
			double pos = at * s.rate;
			int64_t f0 = (int64_t)std::floor(pos);
			if (f0 < 0 || f0 >= s.frames) {
				continue;
			}
			double frac = pos - f0;
			int64_t f1 = std::min(f0 + 1, s.frames - 1);
			float gl = s.samples[f0 * 2] + (float)frac * (s.samples[f1 * 2] - s.samples[f0 * 2]);
			float gr = s.samples[f0 * 2 + 1] + (float)frac * (s.samples[f1 * 2 + 1] - s.samples[f0 * 2 + 1]);
			float g = c.gain;
			if (c.fade_in > 0 && into < c.fade_in) {
				g *= fade_gain((double)into / c.fade_in, c.fade_shape);
			}
			int64_t left = c.length - into;
			if (c.fade_out > 0 && left <= c.fade_out) {
				g *= fade_gain((double)(left - 1) / c.fade_out, c.fade_shape);
			}
			l += gl * g;
			r += gr * g;
		}
		buffer[i].left = l;
		buffer[i].right = r;
	}
	return frames;
}
