#include "dawkit_transport.h"

#include <godot_cpp/core/class_db.hpp>

#include <cmath>

using namespace godot;

int64_t DawKitTransport::claim_block(int64_t &seen, int64_t frames) {
	int64_t now = clock.load();
	int64_t start;
	if (seen == now) {
		// The first lane in this block: the block starts here, and the clock moves past it.
		int64_t expected = now;
		if (clock.compare_exchange_strong(expected, now + frames)) {
			start = now;
		} else {
			// Another lane moved it in between: this block is the one it started.
			start = expected - frames;
		}
	} else {
		// Mixed after another lane in the same block. A lane that missed blocks lands here too,
		// a block late for one block, and is back in step after it.
		start = now - frames;
	}
	seen = start + frames;
	return start;
}

int64_t DawKitTransport::song_frame_at(int64_t at) const {
	if (!playing.load()) {
		return NOT_PLAYING;
	}
	int64_t since = at - anchor_clock.load();
	if (since < 0) {
		return NOT_PLAYING;
	}
	int64_t song = anchor_song.load() + since;
	if (looping.load()) {
		int64_t from = loop_from.load();
		int64_t to = loop_to.load();
		if (to > from && song >= to) {
			song = from + (song - to) % (to - from);
		}
	}
	return song;
}

void DawKitTransport::play_from(double seconds, double lead) {
	int64_t r = rate.load();
	// Stopped first, so no lane reads a half-set anchor.
	playing.store(false);
	anchor_song.store((int64_t)std::llround(seconds * r));
	anchor_clock.store(clock.load() + (int64_t)std::llround(std::max(lead, 0.0) * r));
	playing.store(true);
}

void DawKitTransport::stop() {
	playing.store(false);
}

double DawKitTransport::song_seconds() const {
	int64_t at = song_frame_at(clock.load());
	if (at == NOT_PLAYING) {
		return (double)anchor_song.load() / rate.load();
	}
	return (double)at / rate.load();
}

void DawKitTransport::set_loop(double from, double to, bool on) {
	int64_t r = rate.load();
	loop_from.store((int64_t)std::llround(from * r));
	loop_to.store((int64_t)std::llround(to * r));
	looping.store(on);
}

void DawKitTransport::set_hold(double seconds) {
	hold.store(seconds < 0.0 ? -1 : (int64_t)std::llround(seconds * rate.load()));
}

void DawKitTransport::set_tempo(double bpm, int num, int den) {
	tempo.store(bpm > 0.0 ? bpm : 120.0);
	numerator.store(num > 0 ? num : 4);
	denominator.store(den > 0 ? den : 4);
}

void DawKitTransport::describe(int64_t at, dawkit::Transport &out) const {
	int64_t song = song_frame_at(at);
	int r = rate.load();
	out.rate = r;
	out.playing = song != NOT_PLAYING;
	if (!out.playing) {
		song = anchor_song.load();
	}
	out.seconds = (double)song / r;
	out.tempo = tempo.load();
	out.numerator = numerator.load();
	out.denominator = denominator.load();
	out.beats = out.seconds * out.tempo / 60.0;
	double bar = out.numerator * 4.0 / out.denominator;
	out.bar_start = bar > 0.0 ? std::floor(out.beats / bar) * bar : 0.0;
	out.frames = at;
}

void DawKitTransport::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_tempo", "bpm", "numerator", "denominator"), &DawKitTransport::set_tempo,
			DEFVAL(4), DEFVAL(4));
	ClassDB::bind_method(D_METHOD("get_tempo"), &DawKitTransport::get_tempo);
	ClassDB::bind_method(D_METHOD("set_hold", "seconds"), &DawKitTransport::set_hold);
	ClassDB::bind_method(D_METHOD("play_from", "seconds", "lead"), &DawKitTransport::play_from);
	ClassDB::bind_method(D_METHOD("stop"), &DawKitTransport::stop);
	ClassDB::bind_method(D_METHOD("is_playing"), &DawKitTransport::is_playing);
	ClassDB::bind_method(D_METHOD("song_seconds"), &DawKitTransport::song_seconds);
	ClassDB::bind_method(D_METHOD("get_anchor_clock"), &DawKitTransport::get_anchor_clock);
	ClassDB::bind_method(D_METHOD("get_clock"), &DawKitTransport::get_clock);
	ClassDB::bind_method(D_METHOD("set_rate", "rate"), &DawKitTransport::set_rate);
	ClassDB::bind_method(D_METHOD("get_rate"), &DawKitTransport::get_rate);
	ClassDB::bind_method(D_METHOD("set_loop", "from", "to", "on"), &DawKitTransport::set_loop);
}
