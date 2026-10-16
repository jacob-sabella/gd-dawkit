class_name DawKitFlacWriter
extends RefCounted

## FLAC, encoded: what `DawKitFlac` reads, written from the same specification (RFC 9639).
##
## Each channel of a block of 4096 frames is coded on its own, as the cheapest of constant,
## verbatim or a fixed predictor of order 0 to 4, its residual Rice coded in up to 32 partitions.
## No stereo decorrelation and no LPC, so files come out larger than the reference encoder's
## (typically a tenth to a fifth) but are exact: STREAMINFO carries the MD5 of the sound and any
## decoder agrees with it. 8, 12, 16, 20, 24 and 32-bit sound, any number of channels up to 8.

const BLOCK := 4096
const MAX_PARTITION_ORDER := 5
const MAX_RICE := 14


## `samples` are the integers to store, interleaved, `bits` deep each. Answers the file's bytes,
## or an empty array if the shape is not one FLAC can hold.
static func encode_ints(samples: PackedInt64Array, channels: int, rate: int, bits: int) -> PackedByteArray:
	if channels < 1 or channels > 8 or bits < 4 or bits > 32 or rate < 1 or rate > 655350 \
			or samples.size() % channels != 0:
		return PackedByteArray()
	var frames := samples.size() / channels
	var out := PackedByteArray()
	out.append_array("fLaC".to_ascii_buffer())
	var head := _W.new()
	head.put(0x80, 8)  # last metadata block, STREAMINFO
	head.put(34, 24)
	head.put(BLOCK, 16)
	head.put(BLOCK, 16)
	head.put(0, 24)
	head.put(0, 24)
	head.put(rate, 20)
	head.put(channels - 1, 3)
	head.put(bits - 1, 5)
	head.put(frames >> 32, 4)
	head.put(frames & 0xFFFFFFFF, 32)
	var md5_at := out.size() + head.bytes().size()
	out.append_array(head.bytes())
	out.append_array(_md5(samples, bits))
	var number := 0
	var at := 0
	while at < frames:
		var block := mini(BLOCK, frames - at)
		out.append_array(_frame(samples, channels, bits, at, block, number))
		at += block
		number += 1
	# Smallest and largest frame sizes are left unknown (0), as the format allows.
	if md5_at < 0:
		return PackedByteArray()
	return out


## Float samples in -1..1 rounded to `bits` (16 or 24, dithered as DawKitAudioFile's WAVs are)
## and encoded. An Error.
static func write(path: String, samples: PackedFloat32Array, channels: int, rate: int, bits := 24) -> Error:
	if bits != 16 and bits != 24:
		return ERR_INVALID_PARAMETER
	var top := float((1 << (bits - 1)) - 1)
	var low := -(1 << (bits - 1))
	var noise := RandomNumberGenerator.new()
	noise.seed = 0x5EED
	var ints := PackedInt64Array()
	ints.resize(samples.size())
	for i in samples.size():
		ints[i] = clampi(int(roundf(clampf(samples[i], -1.0, 1.0) * top + noise.randf() - noise.randf())), low, int(top))
	var bytes := encode_ints(ints, channels, rate, bits)
	if bytes.is_empty():
		return ERR_INVALID_PARAMETER
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(bytes)
	f.close()
	return OK


static func _frame(samples: PackedInt64Array, channels: int, bits: int, first: int, block: int, number: int) -> PackedByteArray:
	var w := _W.new()
	w.put(0x3FFE, 14)
	w.put(0, 2)  # reserved, fixed block size
	var size_code := 12 if block == BLOCK else 7
	w.put(size_code, 4)
	w.put(0, 4)  # rate from STREAMINFO
	w.put(channels - 1, 4)  # independent channels
	w.put(0, 3)  # depth from STREAMINFO
	w.put(0, 1)
	_utf8(w, number)
	if size_code == 7:
		w.put(block - 1, 16)
	w.put(_crc8(w.bytes()), 8)
	for c in channels:
		var ch := PackedInt64Array()
		ch.resize(block)
		for i in block:
			ch[i] = samples[(first + i) * channels + c]
		_subframe(w, ch, bits)
	w.align()
	var body := w.bytes()
	var crc := _crc16(body)
	body.append(crc >> 8)
	body.append(crc & 0xFF)
	return body


static func _subframe(w: _W, s: PackedInt64Array, bits: int) -> void:
	var n := s.size()
	var same := true
	for i in range(1, n):
		if s[i] != s[0]:
			same = false
			break
	if same:
		w.put(0, 8)
		w.put_signed(s[0], bits)
		return
	var best_order := 0
	var best_sum := -1
	var best_res := PackedInt64Array()
	for order in range(0, mini(5, n)):
		var res := _residual_of(s, order)
		var total := 0
		for i in range(order, n):
			total += absi(res[i])
		if best_sum < 0 or total < best_sum:
			best_sum = total
			best_order = order
			best_res = res
	var plan := _rice_plan(best_res, best_order, n)
	var bits_rice: int = plan["bits"]
	if bits_rice + best_order * bits >= n * bits:
		w.put(1 << 1, 8)  # verbatim
		for v in s:
			w.put_signed(v, bits)
		return
	w.put((8 + best_order) << 1, 8)
	for i in best_order:
		w.put_signed(s[i], bits)
	w.put(0, 2)  # 4-bit Rice parameters
	var po: int = plan["order"]
	w.put(po, 4)
	var per := n >> po
	var at := best_order
	for p in 1 << po:
		var count := per - (best_order if p == 0 else 0)
		var k: int = plan["k"][p]
		w.put(k, 4)
		for i in count:
			var r := best_res[at + i]
			var u := (r << 1) if r >= 0 else ((-r << 1) - 1)
			w.put_unary(u >> k)
			w.put(u & ((1 << k) - 1), k)
		at += count


## The fixed predictor of `order`'s residual at every index from `order` on.
static func _residual_of(s: PackedInt64Array, order: int) -> PackedInt64Array:
	var n := s.size()
	var r := PackedInt64Array()
	r.resize(n)
	match order:
		0:
			for i in n:
				r[i] = s[i]
		1:
			for i in range(1, n):
				r[i] = s[i] - s[i - 1]
		2:
			for i in range(2, n):
				r[i] = s[i] - 2 * s[i - 1] + s[i - 2]
		3:
			for i in range(3, n):
				r[i] = s[i] - 3 * s[i - 1] + 3 * s[i - 2] - s[i - 3]
		_:
			for i in range(4, n):
				r[i] = s[i] - 4 * s[i - 1] + 6 * s[i - 2] - 4 * s[i - 3] + s[i - 4]
	return r


## The cheapest split of a residual into Rice partitions: {order, k (per partition), bits}.
static func _rice_plan(res: PackedInt64Array, order: int, n: int) -> Dictionary:
	var best := {"bits": 1 << 60, "order": 0, "k": [0]}
	for po in range(0, MAX_PARTITION_ORDER + 1):
		var parts := 1 << po
		var per := n >> po
		if per * parts != n or per < order or per < 1:
			break
		var total := 6  # method and partition order
		var ks: Array = []
		var at := order
		for p in parts:
			var count := per - (order if p == 0 else 0)
			var sum := 0
			for i in range(at, at + count):
				var r := res[i]
				sum += (r << 1) if r >= 0 else ((-r << 1) - 1)
			var k := 0
			if count > 0 and sum > count:
				k = clampi(int(floor(log(float(sum) / count) / log(2.0))), 0, MAX_RICE)
			var cost := _rice_bits(res, at, count, k)
			if k < MAX_RICE:
				var more := _rice_bits(res, at, count, k + 1)
				if more < cost:
					cost = more
					k += 1
			ks.append(k)
			total += 4 + cost
			at += count
		if total < int(best["bits"]):
			best = {"bits": total, "order": po, "k": ks}
	return best


static func _rice_bits(res: PackedInt64Array, from: int, count: int, k: int) -> int:
	var total := count * (k + 1)
	for i in range(from, from + count):
		var r := res[i]
		total += ((r << 1) if r >= 0 else ((-r << 1) - 1)) >> k
	return total


static func _md5(samples: PackedInt64Array, bits: int) -> PackedByteArray:
	var width := (bits + 7) / 8
	var raw := PackedByteArray()
	raw.resize(samples.size() * width)
	var at := 0
	for v in samples:
		for b in width:
			raw[at] = (v >> (8 * b)) & 0xFF
			at += 1
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(raw)
	return h.finish()


static func _utf8(w: _W, v: int) -> void:
	if v < 0x80:
		w.put(v, 8)
	elif v < 0x800:
		w.put(0xC0 | (v >> 6), 8)
		w.put(0x80 | (v & 0x3F), 8)
	elif v < 0x10000:
		w.put(0xE0 | (v >> 12), 8)
		w.put(0x80 | ((v >> 6) & 0x3F), 8)
		w.put(0x80 | (v & 0x3F), 8)
	elif v < 0x200000:
		w.put(0xF0 | (v >> 18), 8)
		for sh in [12, 6, 0]:
			w.put(0x80 | ((v >> sh) & 0x3F), 8)
	elif v < 0x4000000:
		w.put(0xF8 | (v >> 24), 8)
		for sh in [18, 12, 6, 0]:
			w.put(0x80 | ((v >> sh) & 0x3F), 8)
	else:
		w.put(0xFC | (v >> 30), 8)
		for sh in [24, 18, 12, 6, 0]:
			w.put(0x80 | ((v >> sh) & 0x3F), 8)


static func _crc8(b: PackedByteArray) -> int:
	var crc := 0
	for byte in b:
		crc ^= byte
		for _i in 8:
			crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
	return crc


static func _crc16(b: PackedByteArray) -> int:
	var crc := 0
	for byte in b:
		crc ^= byte << 8
		for _i in 8:
			crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
	return crc


## Bits written most significant first.
class _W:
	var data := PackedByteArray()
	var acc := 0
	var held := 0

	func put(v: int, n: int) -> void:
		while n > 0:
			var take := mini(n, 8 - held)
			var chunk := (v >> (n - take)) & ((1 << take) - 1)
			acc = (acc << take) | chunk
			held += take
			n -= take
			if held == 8:
				data.append(acc)
				acc = 0
				held = 0

	func put_signed(v: int, n: int) -> void:
		put(v & ((1 << n) - 1), n)

	func put_unary(q: int) -> void:
		while q >= 8:
			put(0, 8)
			q -= 8
		put(1, q + 1)

	func align() -> void:
		if held > 0:
			put(0, 8 - held)

	## The whole bytes so far; call after align for a finished stream.
	func bytes() -> PackedByteArray:
		return data.duplicate()
