class_name DawKitTransients
extends RefCounted

## Where the attacks in a sound are -- the drum hits, the plucks, the consonants -- as seconds into
## the file, to a millisecond or better: what an edge dragged near one is pulled onto, so a clip
## can be trimmed to the hit and not to wherever the beat happens to fall.
##
## Found in two steps. First a coarse look, in hops of HOP_SECONDS, at two bands: the sound's
## energy, and the energy of its sample-to-sample differences -- its top end, which a click, a
## stick or a consonant is mostly made of, and which a held bass note under it has next to none
## of. An onset is wherever the next SHORT_HOPS of either band are RISE_DB louder than the
## BACK_HOPS just before -- a rise against what was already sounding, so a hit over a ringing tail
## is found and the tail is not, and a hi-hat over the bass is found in the top band where the
## whole sound barely changes. Then each onset is walked back, sample by sample in the band that
## rose most, to where its attack starts: the first sample that stands clear of the quiet before
## it, and from there back to where the sound left that quiet.
##
## Finding them reads every sample in script, which for a long take is seconds of work, so a host
## asks with `soon`: what is known already, at once, and the finding started on a worker thread
## if it is not, for the next ask to have. `of_file` waits for it, for a test or a tool. Either
## way a file is looked at once for as long as it is unchanged on disk.

## The coarse look's hop, and so roughly how near an onset the walk back starts from.
const HOP_SECONDS := 0.001
## The stretch after a hop that has to be louder, and the stretch before it that it is compared
## with, in hops.
const SHORT_HOPS := 5
const BACK_HOPS := 40
## How much louder the stretch after has to be for an onset there.
const RISE_DB := 9.0
## Below the loudest hop by this much is silence: nothing in it is an attack, and a rise out of
## it is measured from here, so hiss coming up out of digital silence is not one either.
const FLOOR_DB := 50.0
## Two onsets are never nearer than this: one hit's own wobbles are not more hits.
const MIN_GAP_SECONDS := 0.03
## The walk back from where an attack is first clearly under way goes no further than this.
const WALK_BACK_SECONDS := 0.002
## Of the way from the quiet before an attack up to its peak, where it counts as clearly started.
const CLEAR := 0.1

## The onsets of each file looked at: key (see _key) -> PackedFloat32Array. Guarded by _lock, as
## workers write to it.
static var _found: Dictionary = {}
## Findings under way: key -> WorkerThreadPool task id.
static var _tasks: Dictionary = {}
static var _lock := Mutex.new()


## The onsets in `samples` (interleaved, `channels` of them, at `rate`), in seconds from its start,
## earliest first.
static func find(samples: PackedFloat32Array, channels: int, rate: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	channels = maxi(channels, 1)
	var frames := samples.size() / channels
	if frames < 2 or rate <= 0:
		return out
	var hop := maxi(roundi(rate * HOP_SECONDS), 1)
	var hops := frames / hop
	if hops < 2:
		return out
	# One pass: the sound folded to mono and its differences, each band's energy hop by hop (as
	# prefix sums, so any stretch's mean is two lookups) and each hop's loudest sample.
	var n := hops * hop
	var body := PackedFloat32Array()
	body.resize(n)
	var edge := PackedFloat32Array()
	edge.resize(n)
	var body_sums := PackedFloat64Array()
	body_sums.resize(hops + 1)
	var edge_sums := PackedFloat64Array()
	edge_sums.resize(hops + 1)
	var body_top := PackedFloat32Array()
	body_top.resize(hops)
	var edge_top := PackedFloat32Array()
	edge_top.resize(hops)
	var scale := 1.0 / channels
	var previous := 0.0
	var body_total := 0.0
	var edge_total := 0.0
	var body_loudest := 0.0
	var edge_loudest := 0.0
	var i := 0
	for h in hops:
		var be := 0.0
		var ee := 0.0
		var bp := 0.0
		var ep := 0.0
		for _k in hop:
			var m := 0.0
			if channels == 2:
				m = (samples[i * 2] + samples[i * 2 + 1]) * 0.5
			elif channels == 1:
				m = samples[i]
			else:
				for c in channels:
					m += samples[i * channels + c]
				m *= scale
			var d := m - previous
			previous = m
			body[i] = m
			edge[i] = d
			be += m * m
			ee += d * d
			bp = maxf(bp, absf(m))
			ep = maxf(ep, absf(d))
			i += 1
		be /= hop
		ee /= hop
		body_total += be
		edge_total += ee
		body_sums[h + 1] = body_total
		edge_sums[h + 1] = edge_total
		body_top[h] = bp
		edge_top[h] = ep
		body_loudest = maxf(body_loudest, be)
		edge_loudest = maxf(edge_loudest, ee)
	if body_loudest <= 0.0:
		return out
	var floor_ratio := pow(10.0, -FLOOR_DB / 10.0)
	var body_quiet := maxf(body_loudest * floor_ratio, 1e-12)
	var edge_quiet := maxf(edge_loudest * floor_ratio, 1e-12)
	var rise := pow(10.0, RISE_DB / 10.0)
	var gap := maxi(roundi(MIN_GAP_SECONDS / (float(hop) / rate)), 1)
	var allowed := 0
	for h in range(1, hops):
		if h < allowed:
			continue
		var body_rise := _rise(body_sums, h, hops, body_quiet)
		var edge_rise := _rise(edge_sums, h, hops, edge_quiet)
		if body_rise < rise and edge_rise < rise:
			continue
		var at := _attack_start(body, body_top, h, hop, rate) if body_rise >= edge_rise \
				else _attack_start(edge, edge_top, h, hop, rate)
		out.append(float(at) / rate)
		allowed = at / hop + gap
	return out


## How many times louder a band's next SHORT_HOPS from hop `h` are than its BACK_HOPS before,
## each measured from `quiet` up.
static func _rise(sums: PackedFloat64Array, h: int, hops: int, quiet: float) -> float:
	var ahead_end := mini(h + SHORT_HOPS, hops)
	var back_start := maxi(h - BACK_HOPS, 0)
	var ahead := (sums[ahead_end] - sums[h]) / (ahead_end - h)
	var back := (sums[h] - sums[back_start]) / (h - back_start)
	return (ahead + quiet) / (back + quiet)


## The sample an attack first noticed at hop `h` (its rise is in the SHORT_HOPS from there) starts
## at, in `band` (whose loudest sample in each hop is `top`): the first after the quiet before it
## to stand CLEAR of that quiet toward its peak, walked back to where the band left the quiet.
static func _attack_start(band: PackedFloat32Array, top: PackedFloat32Array, h: int, hop: int, rate: int) -> int:
	var before := 0.0
	for k in range(maxi(h - 3, 0), h):
		before = maxf(before, top[k])
	var peak := 0.0
	for k in range(h, mini(h + SHORT_HOPS + 2, top.size())):
		peak = maxf(peak, top[k])
	var clear := before + (peak - before) * CLEAR
	var from := h * hop
	var to := mini((h + SHORT_HOPS + 2) * hop, band.size())
	var at := from
	for s in range(from, to):
		if absf(band[s]) > clear:
			at = s
			break
	var furthest := maxi(at - maxi(roundi(rate * WALK_BACK_SECONDS), 1), 0)
	while at > furthest and absf(band[at - 1]) > before and absf(band[at - 1]) <= absf(band[at]) + 1e-9:
		at -= 1
	return at


## The onsets of the sound file at `path` (any DawKitAudioFile reads), or of that sound played
## backwards, waiting for them if they have not been found yet. Empty for a file that cannot be read.
static func of_file(path: String, reversed := false) -> PackedFloat32Array:
	var key := _key(path, reversed)
	var task := -1
	_lock.lock()
	if _found.has(key):
		var known: PackedFloat32Array = _found[key]
		_lock.unlock()
		return known
	task = _tasks.get(key, -1)
	_lock.unlock()
	if task >= 0:
		WorkerThreadPool.wait_for_task_completion(task)
		_lock.lock()
		_tasks.erase(key)
		_lock.unlock()
	else:
		_work(path, reversed, key)
	_lock.lock()
	var got: PackedFloat32Array = _found.get(key, PackedFloat32Array())
	_lock.unlock()
	return got


## The onsets of the file at `path` if they are known, at once; if not, empty, and they are
## looked for on a worker thread so that a later ask has them. What a host answers a drag with:
## a drag never waits on a file.
static func soon(path: String, reversed := false) -> PackedFloat32Array:
	if path.is_empty() or not FileAccess.file_exists(path):
		return PackedFloat32Array()
	var key := _key(path, reversed)
	_lock.lock()
	var known: Variant = _found.get(key)
	var task: int = _tasks.get(key, -1)
	_lock.unlock()
	if known != null:
		if task >= 0:
			WorkerThreadPool.wait_for_task_completion(task)
			_lock.lock()
			_tasks.erase(key)
			_lock.unlock()
		return known
	if task < 0:
		task = WorkerThreadPool.add_task(DawKitTransients._work.bind(path, reversed, key), false, "dawkit transients")
		_lock.lock()
		_tasks[key] = task
		_lock.unlock()
	return PackedFloat32Array()


## Waits for every finding under way, so that what `soon` started is known. For tests.
static func settle() -> void:
	_lock.lock()
	var tasks := _tasks.duplicate()
	_tasks.clear()
	_lock.unlock()
	for key in tasks:
		WorkerThreadPool.wait_for_task_completion(tasks[key])


## Forgets every file looked at.
static func forget() -> void:
	settle()
	_lock.lock()
	_found.clear()
	_lock.unlock()


static func _work(path: String, reversed: bool, key: String) -> void:
	var sound := DawKitAudioFile.read(path)
	var onsets := PackedFloat32Array()
	if str(sound.get("error", "")).is_empty() and sound.get("samples") != null:
		var samples: PackedFloat32Array = sound["samples"]
		if reversed:
			samples = samples.duplicate()
			samples.reverse()
		onsets = find(samples, int(sound["channels"]), int(sound["rate"]))
	_lock.lock()
	_found[key] = onsets
	_lock.unlock()


## A file is the same file while its path and when it was last written are: written again (a take
## recorded over, a sound processed), it is looked at again.
static func _key(path: String, reversed: bool) -> String:
	return "%s|%d|%s" % [path, FileAccess.get_modified_time(path), "r" if reversed else "f"]


## A clip's onsets in song seconds, from its file's (`onsets`, seconds into the sound as the clip
## plays it, so a reversed clip's are the reversed sound's): where each is heard with the clip's
## left edge at `start`, `source_offset` into the sound. Every onset of the sound, not only those
## between the clip's edges, so an edge dragged outward is pulled onto the attacks it uncovers;
## for a looped clip (loop_end after loop_start), each pass of the loop's, up to `reach` seconds
## past the clip's end.
static func placed(onsets: PackedFloat32Array, start: float, source_offset: float, length: float,
		loop_start := 0.0, loop_end := 0.0, reach := 30.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if loop_end <= loop_start:
		out.resize(onsets.size())
		for k in onsets.size():
			out[k] = start - source_offset + onsets[k]
		return out
	for f in onsets:
		if f >= source_offset and f < loop_end:
			out.append(start + f - source_offset)
	var span := loop_end - loop_start
	var pass_start := start + maxf(loop_end - source_offset, 0.0)
	while pass_start < start + length + reach and out.size() < 100000:
		for f in onsets:
			if f >= loop_start and f < loop_end:
				out.append(pass_start + f - loop_start)
		pass_start += span
	return out


## The time in `times` (earliest first) nearest `seconds`, or NAN when there are none.
static func nearest(times: PackedFloat32Array, seconds: float) -> float:
	if times.is_empty():
		return NAN
	var at := times.bsearch(seconds)
	var best := NAN
	for k in [at - 1, at]:
		if k >= 0 and k < times.size() and (is_nan(best) or absf(times[k] - seconds) < absf(best - seconds)):
			best = times[k]
	return best
