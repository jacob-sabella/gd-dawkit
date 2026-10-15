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
		} else if (d.has("wav")) {
			Ref<AudioStreamWAV> wav = d["wav"];
			auto s = std::make_shared<Sound>();
			if (wav.is_valid()) {
				PackedByteArray data = wav->get_data();
				int channels = wav->is_stereo() ? 2 : 1;
				s->rate = std::max(wav->get_mix_rate(), 1);
				const uint8_t *b = data.ptr();
				int width = 0;
				switch (wav->get_format()) {
					case AudioStreamWAV::FORMAT_8_BITS: width = 1; break;
					case AudioStreamWAV::FORMAT_16_BITS: width = 2; break;
					default: width = 0; break;
				}
				if (width > 0) {
					s->frames = data.size() / (width * channels);
					s->samples.resize(s->frames * 2);
					for (int64_t f = 0; f < s->frames; f++) {
						for (int ch = 0; ch < 2; ch++) {
							int64_t at = (f * channels + std::min(ch, channels - 1)) * width;
							float v = width == 1 ? (int8_t)b[at] / 128.0f
												 : (int16_t)(b[at] | (b[at + 1] << 8)) / 32768.0f;
							s->samples[f * 2 + ch] = v;
						}
					}
				}
			}
			sound = s;
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
		c.fade_out_shape = d.get("fade_out_shape", c.fade_shape);
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

void DawKitLane::publish(std::shared_ptr<const Instrument> next) {
	std::shared_ptr<const Instrument> was = std::atomic_exchange(&instrument, next);
	if (was) {
		retired.push_back(was);
	}
	// Only this lane and its retired list hold one the mixer is not using.
	retired.erase(std::remove_if(retired.begin(), retired.end(),
						  [](const std::shared_ptr<const Instrument> &r) { return r.use_count() == 1; }),
			retired.end());
}

void DawKitLane::set_instrument(const Ref<DawKitPlugin> &p) {
	instrument_ref = p;
	std::shared_ptr<const Instrument> had = std::atomic_load(&instrument);
	if (p.is_null()) {
		publish(nullptr);
		return;
	}
	auto next = std::make_shared<Instrument>();
	next->plugin = p;
	if (had) {
		next->notes = had->notes;
	} else if (!pending_notes.empty()) {
		next->notes = pending_notes;
	}
	publish(next);
}

void DawKitLane::set_notes(const PackedFloat64Array &flat) {
	int rate = transport.is_valid() ? transport->get_rate() : 48000;
	std::vector<Note> notes;
	const double *v = flat.ptr();
	for (int64_t i = 0; i + 4 < flat.size(); i += 5) {
		Note n;
		n.start = (int64_t)std::llround(v[i] * rate);
		n.end = std::max(n.start + 1, (int64_t)std::llround(v[i + 1] * rate));
		n.key = (uint8_t)std::clamp((int)v[i + 2], 0, 127);
		n.velocity = (uint8_t)std::clamp((int)std::lround(v[i + 3]), 1, 127);
		n.channel = (uint8_t)std::clamp((int)v[i + 4], 0, 15);
		notes.push_back(n);
	}
	std::stable_sort(notes.begin(), notes.end(), [](const Note &a, const Note &b) { return a.start < b.start; });
	pending_notes = notes;
	if (instrument_ref.is_null()) {
		return;
	}
	auto next = std::make_shared<Instrument>();
	next->plugin = instrument_ref;
	next->notes = std::move(notes);
	publish(next);
}

int DawKitLane::note_count() const {
	return (int)pending_notes.size();
}

void DawKitLane::mix_instrument(int64_t block, AudioFrame *buffer, int32_t frames) {
	std::shared_ptr<const Instrument> inst = std::atomic_load(&instrument);
	if (!inst || inst->plugin.is_null()) {
		return;
	}
	DawKitPlugin *p = inst->plugin.ptr();
	if (!p->is_active() || p->max_block_size() <= 0) {
		return;
	}
	if (block != made_block || (int32_t)made_l.size() != frames) {
		made_block = block;
		if ((int32_t)made_l.capacity() < frames) {
			made_l.reserve(std::max(frames, 4096));
			made_r.reserve(std::max(frames, 4096));
		}
		made_l.assign(frames, 0.0f);
		made_r.assign(frames, 0.0f);
		if (events.capacity() < 4096) {
			events.reserve(4096);
			sounding.reserve(1024);
		}
		Ref<DawKitTransport> t = transport;
		const int64_t hold = held.load() ? t->get_hold_frame() : -1;
		int block_size = p->max_block_size();
		for (int32_t at = 0; at < frames; at += block_size) {
			int32_t n = std::min<int32_t>(block_size, frames - at);
			events.clear();
			auto push = [&](dawkit::Event e) {
				if (events.size() < events.capacity()) events.push_back(e);
			};
			auto off = [&](const Sounding &s, int32_t offset) {
				dawkit::Event e;
				e.kind = dawkit::Event::NOTE_OFF;
				e.key = s.key;
				e.channel = s.channel;
				e.offset = offset;
				push(e);
			};
			// The block in runs of song frames one after another: a loop's wrap or a jump ends one.
			int32_t i = 0;
			while (i < n) {
				int64_t song = t->song_frame_at(block + at + i);
				if (song == DawKitTransport::NOT_PLAYING) {
					if (last_song != DawKitTransport::NOT_PLAYING) {
						for (const Sounding &s : sounding) off(s, i);
						sounding.clear();
					}
					last_song = DawKitTransport::NOT_PLAYING;
					i++;
					while (i < n && t->song_frame_at(block + at + i) == DawKitTransport::NOT_PLAYING) i++;
					continue;
				}
				if (last_song != DawKitTransport::NOT_PLAYING && song != last_song + 1) {
					for (const Sounding &s : sounding) off(s, i);
					sounding.clear();
				}
				int32_t j = i + 1;
				while (j < n && t->song_frame_at(block + at + j) == song + (j - i)) j++;
				int64_t from = song, to = song + (j - i); // [from, to)
				// Endings first, so a note played again on the same key starts after it stops.
				for (size_t k = 0; k < sounding.size();) {
					if (sounding[k].end >= from && sounding[k].end < to) {
						off(sounding[k], i + (int32_t)(sounding[k].end - from));
						sounding[k] = sounding.back();
						sounding.pop_back();
					} else {
						k++;
					}
				}
				const std::vector<Note> &notes = inst->notes;
				auto first = std::lower_bound(notes.begin(), notes.end(), from,
						[](const Note &nt, int64_t f) { return nt.start < f; });
				for (auto it = first; it != notes.end() && it->start < to; ++it) {
					if (hold >= 0 && it->start < hold) continue;
					dawkit::Event e;
					e.kind = dawkit::Event::NOTE_ON;
					e.key = it->key;
					e.channel = it->channel;
					e.value = it->velocity / 127.0;
					e.offset = i + (int32_t)(it->start - from);
					push(e);
					Sounding s{ it->key, it->channel, it->end };
					if (it->end < to) {
						// A note shorter than what is left of the run ends in it.
						off(s, i + (int32_t)(it->end - from));
					} else if (sounding.size() < sounding.capacity()) {
						sounding.push_back(s);
					}
				}
				last_song = to - 1;
				i = j;
			}
			std::stable_sort(events.begin(), events.end(),
					[](const dawkit::Event &a, const dawkit::Event &b) { return a.offset < b.offset; });
			dawkit::Transport where;
			t->describe(block + at, where);
			if ((int32_t)silence.size() < block_size) {
				silence.assign(block_size, 0.0f);
			}
			const float *in[2] = { silence.data(), silence.data() };
			float *out[2] = { made_l.data() + at, made_r.data() + at };
			p->run(in, out, n, events.data(), (int)events.size(), where);
			if (p->output_channels() == 1) {
				std::copy(made_l.begin() + at, made_l.begin() + at + n, made_r.begin() + at);
			}
		}
	}
	for (int32_t i = 0; i < frames; i++) {
		buffer[i].left += made_l[i];
		buffer[i].right += made_r[i];
	}
}

void DawKitLane::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_instrument", "plugin"), &DawKitLane::set_instrument);
	ClassDB::bind_method(D_METHOD("get_instrument"), &DawKitLane::get_instrument);
	ClassDB::bind_method(D_METHOD("set_notes", "notes"), &DawKitLane::set_notes);
	ClassDB::bind_method(D_METHOD("note_count"), &DawKitLane::note_count);
	ClassDB::bind_method(D_METHOD("set_transport", "transport"), &DawKitLane::set_transport);
	ClassDB::bind_method(D_METHOD("get_transport"), &DawKitLane::get_transport);
	ClassDB::bind_method(D_METHOD("set_clips", "clips"), &DawKitLane::set_clips);
	ClassDB::bind_method(D_METHOD("clip_count"), &DawKitLane::clip_count);
	ClassDB::bind_method(D_METHOD("set_held", "held"), &DawKitLane::set_held);
	ClassDB::bind_method(D_METHOD("get_held"), &DawKitLane::get_held);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "transport", PROPERTY_HINT_RESOURCE_TYPE, "DawKitTransport"),
			"set_transport", "get_transport");
}

// How loud a fade is `t` (0-1) of the way in.
static inline float fade_gain(double t, int shape) {
	t = std::clamp(t, 0.0, 1.0);
	// DawKitClip.fade_gain's shapes, in the same order.
	switch (shape) {
		case 1:
			return (float)std::sin(t * 1.5707963267948966);
		case 2:
			return (float)(t * t);
		case 3:
			return (float)(1.0 - (1.0 - t) * (1.0 - t));
		case 4:
			return (float)(0.5 - 0.5 * std::cos(t * 3.141592653589793));
		default:
			return (float)t;
	}
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
		lane->mix_instrument(block, buffer, frames);
		return frames;
	}
	std::shared_ptr<const DawKitLane::Clips> clips = lane->snapshot();
	const double rate = t->get_rate();
	const int64_t hold = lane->get_held() ? t->get_hold_frame() : -1;
	for (int32_t i = 0; i < frames; i++) {
		int64_t song = t->song_frame_at(block + i);
		if (song == DawKitTransport::NOT_PLAYING || (hold >= 0 && song < hold)) {
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
			// The lower of the two fades, as an item's level is: a short item's fades cross.
			float shaped = 1.0f;
			if (c.fade_in > 0 && into < c.fade_in) {
				shaped = std::min(shaped, fade_gain((double)into / c.fade_in, c.fade_shape));
			}
			int64_t left = c.length - into;
			if (c.fade_out > 0 && left <= c.fade_out) {
				shaped = std::min(shaped, fade_gain((double)(left - 1) / c.fade_out, c.fade_out_shape));
			}
			float g = c.gain * shaped;
			l += gl * g;
			r += gr * g;
		}
		buffer[i].left = l;
		buffer[i].right = r;
	}
	lane->mix_instrument(block, buffer, frames);
	return frames;
}
