#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

#include <atomic>
#include <cstdint>

namespace godot {

// The song's clock, shared by every lane that plays it, and the one thing they agree on.
//
// Godot mixes each stream once per block, one after another, but cannot start them on a given
// sample: two players told to play together can sound a block apart. So nothing here is started.
// Every lane plays all the time, and asks the transport where the song is at each sample of each
// block. The block clock is counted by the lanes themselves: the first lane mixed in a block moves
// it on, the rest find it already moved (see `claim_block`). The song is anchored to that clock:
// "song frame S at clock frame C", set from the main thread, so every lane turns a clock frame into
// the same song frame, to the sample.
class DawKitTransport : public RefCounted {
	GDCLASS(DawKitTransport, RefCounted)

public:
	// The frames this lane had mixed before this block -> the clock frame the block starts at.
	int64_t claim_block(int64_t &seen, int64_t frames);
	// The song frame at clock frame `clock`, or -1 while stopped or before the start.
	int64_t song_frame_at(int64_t clock) const;

	// Starts the song at `seconds`, `lead` seconds from the clock's last block: far enough ahead
	// that no lane has mixed past it yet, so every lane starts it on the same sample.
	void play_from(double seconds, double lead);
	void stop();
	bool is_playing() const { return playing.load(); }
	// Where the song is, as the lanes last mixed it.
	double song_seconds() const;
	// The clock frame the song started at (play_from), and the clock now.
	int64_t get_anchor_clock() const { return anchor_clock.load(); }
	int64_t get_clock() const { return clock.load(); }

	void set_rate(int p_rate) { rate.store(p_rate > 0 ? p_rate : 48000); }
	int get_rate() const { return rate.load(); }
	// A loop range in seconds: the song goes round it while `looping`. Both 0 for none.
	void set_loop(double from, double to, bool on);

protected:
	static void _bind_methods();

private:
	std::atomic<int64_t> clock{ 0 };
	std::atomic<int64_t> anchor_clock{ 0 };
	std::atomic<int64_t> anchor_song{ 0 };
	std::atomic<bool> playing{ false };
	std::atomic<int> rate{ 48000 };
	std::atomic<int64_t> loop_from{ 0 };
	std::atomic<int64_t> loop_to{ 0 };
	std::atomic<bool> looping{ false };
};

} // namespace godot
