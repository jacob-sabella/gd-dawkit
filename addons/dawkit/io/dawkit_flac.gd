class_name DawKitFlac
extends RefCounted

## FLAC, decoded: every kind of subframe (constant, verbatim, fixed, LPC), both residual codings
## and their escapes, wasted bits, the three stereo decorrelations, and any bit depth from 4 to 32.
##
## Written from the format's specification (RFC 9639), not from any library. A file whose
## STREAMINFO carries an MD5 of its sound is checked against it, so a file that decodes is known
## to have decoded to exactly what was encoded.

## [samples (PackedInt64Array, interleaved), channels, rate, bits per sample, frames, error].
## The samples are the integers the file holds, not scaled.
static func decode_ints(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 42 or bytes.slice(0, 4).get_string_from_ascii() != "fLaC":
		return {"error": "not a FLAC file"}
	var at := 4
	var info := {}
	while at + 4 <= bytes.size():
		var head := bytes[at]
		var size := (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]
		if head & 0x7F == 0 and size >= 34 and at + 4 + 34 <= bytes.size():
			info = _stream_info(bytes, at + 4)
		at += 4 + size
		if head & 0x80:
			break
	if info.is_empty():
		return {"error": "the FLAC file has no STREAMINFO"}
	var channels: int = info["channels"]
	var bits: int = info["bits"]
	var total: int = info["total"]
	var reader := _Bits.new(bytes, at)
	var out := PackedInt64Array()
	if total > 0:
		out.resize(total * channels)
	var frames := 0
	while reader.pos + 16 <= reader.end:
		var from := reader.pos
		var done := _frame(reader, info, out, frames)
		if done < 0 or reader.pos > reader.end:
			if reader.pos > reader.end:
				# The last frame runs off the end: the file was cut short.
				reader.pos = from
				break
			if frames > 0 and (total == 0 or frames >= total):
				break
			return {"error": "the FLAC file is damaged at byte %d" % (from >> 3)}
		frames += done
		if total > 0 and frames >= total:
			break
	if total > 0 and frames < total:
		return {"error": "the FLAC file ends %d samples short" % (total - frames)}
	out.resize(frames * channels)
	var md5: PackedByteArray = info["md5"]
	if md5.count(0) != 16 and _md5(out, bits) != md5:
		return {"error": "the FLAC file did not decode to what was encoded (its MD5 differs)"}
	return {"samples": out, "channels": channels, "rate": info["rate"], "bits": bits, "frames": frames, "error": ""}


static func _stream_info(b: PackedByteArray, at: int) -> Dictionary:
	var rate := (b[at + 10] << 12) | (b[at + 11] << 4) | (b[at + 12] >> 4)
	var channels := ((b[at + 12] >> 1) & 7) + 1
	var bits := (((b[at + 12] & 1) << 4) | (b[at + 13] >> 4)) + 1
	var total := ((b[at + 13] & 0x0F) << 32) | (b[at + 14] << 24) | (b[at + 15] << 16) | (b[at + 16] << 8) | b[at + 17]
	return {"rate": rate, "channels": channels, "bits": bits, "total": total, "md5": b.slice(at + 18, at + 34)}


## One frame into `out` from frame `first`: how many frames it held, or -1 if it does not read.
static func _frame(r: _Bits, info: Dictionary, out: PackedInt64Array, first: int) -> int:
	r.align()
	if r.bits(14) != 0x3FFE:
		return -1
	r.bits(2)
	var size_code := r.bits(4)
	var rate_code := r.bits(4)
	var assignment := r.bits(4)
	var depth_code := r.bits(3)
	r.bits(1)
	# The frame or sample number, UTF-8 style: only its length matters here.
	var lead := r.bits(8)
	var more := 0
	while more < 7 and (lead << more) & 0x80:
		more += 1
	for i in maxi(more - 1, 0):
		r.bits(8)
	var block := 0
	match size_code:
		1: block = 192
		2, 3, 4, 5: block = 576 << (size_code - 2)
		6: block = r.bits(8) + 1
		7: block = r.bits(16) + 1
		_: block = 256 << (size_code - 8) if size_code >= 8 else 0
	match rate_code:
		12: r.bits(8)
		13, 14: r.bits(16)
	r.bits(8)  # CRC-8 of the header; the MD5 of the whole stands for it
	if block <= 0 or assignment > 10:
		return -1
	var bits: int = info["bits"]
	match depth_code:
		1: bits = 8
		2: bits = 12
		4: bits = 16
		5: bits = 20
		6: bits = 24
		7: bits = 32
	var channels: int = info["channels"]
	var coded := assignment + 1 if assignment < 8 else 2
	if coded != channels:
		return -1
	# A stream longer than STREAMINFO says is kept to its length.
	var keep := block
	if out.size() < (first + block) * channels:
		if int(info["total"]) > 0:
			keep = out.size() / channels - first
			if keep <= 0:
				return -1
		else:
			out.resize((first + block) * channels)
	var sub: Array = []
	for c in channels:
		var extra := 1 if (assignment == 8 and c == 1) or (assignment == 9 and c == 0) or (assignment == 10 and c == 1) else 0
		var s := _subframe(r, block, bits + extra)
		if s.is_empty() and block > 0:
			return -1
		sub.append(s)
	if assignment >= 8:
		var a: PackedInt64Array = sub[0]
		var b: PackedInt64Array = sub[1]
		for i in block:
			var x := a[i]
			var y := b[i]
			match assignment:
				8:  # left, side
					b[i] = x - y
				9:  # side, right
					a[i] = x + y
				10:  # mid, side
					var mid := (x << 1) | (y & 1)
					a[i] = (mid + y) >> 1
					b[i] = (mid - y) >> 1
		sub[0] = a
		sub[1] = b
	for c in channels:
		var s: PackedInt64Array = sub[c]
		var at := first * channels + c
		for i in keep:
			out[at] = s[i]
			at += channels
	r.align()
	r.bits(16)  # CRC-16
	return keep


## One channel's samples for a block, or [] if it does not read.
static func _subframe(r: _Bits, block: int, bits: int) -> PackedInt64Array:
	if r.bits(1) != 0:
		return PackedInt64Array()
	var kind := r.bits(6)
	var wasted := 0
	if r.bits(1):
		wasted = r.unary() + 1
		bits -= wasted
	var s := PackedInt64Array()
	s.resize(block)
	if kind == 0:
		s.fill(r.signed(bits))
	elif kind == 1:
		for i in block:
			s[i] = r.signed(bits)
	elif kind >= 8 and kind <= 12:
		var order := kind - 8
		for i in order:
			s[i] = r.signed(bits)
		if not _residual(r, s, order, block):
			return PackedInt64Array()
		_fixed(s, order, block)
	elif kind >= 32:
		var order := kind - 31
		for i in order:
			s[i] = r.signed(bits)
		var precision := r.bits(4) + 1
		if precision == 16:
			return PackedInt64Array()
		var shift := r.signed(5)
		var coefs := PackedInt64Array()
		coefs.resize(order)
		for j in order:
			coefs[j] = r.signed(precision)
		if not _residual(r, s, order, block):
			return PackedInt64Array()
		_lpc(s, coefs, maxi(shift, 0), order, block)
	else:
		return PackedInt64Array()
	if wasted > 0:
		for i in block:
			s[i] <<= wasted
	return s


## The residual after the warm-up, into `s` from `order` on.
static func _residual(r: _Bits, s: PackedInt64Array, order: int, block: int) -> bool:
	var method := r.bits(2)
	if method > 1:
		return false
	var param_bits := 4 if method == 0 else 5
	var escape := (1 << param_bits) - 1
	var partition_order := r.bits(4)
	var parts := 1 << partition_order
	var per := block >> partition_order
	if per * parts != block or per < order:
		return false
	var at := order
	for p in parts:
		var count := per - (order if p == 0 else 0)
		var param := r.bits(param_bits)
		if param == escape:
			var raw := r.bits(5)
			for i in count:
				s[at] = r.signed(raw) if raw > 0 else 0
				at += 1
		else:
			if not r.rice(s, at, count, param):
				return false
			at += count
	return true


static func _fixed(s: PackedInt64Array, order: int, block: int) -> void:
	match order:
		1:
			for i in range(1, block):
				s[i] += s[i - 1]
		2:
			for i in range(2, block):
				s[i] += 2 * s[i - 1] - s[i - 2]
		3:
			for i in range(3, block):
				s[i] += 3 * s[i - 1] - 3 * s[i - 2] + s[i - 3]
		4:
			for i in range(4, block):
				s[i] += 4 * s[i - 1] - 6 * s[i - 2] + 4 * s[i - 3] - s[i - 4]


static func _lpc(s: PackedInt64Array, coefs: PackedInt64Array, shift: int, order: int, block: int) -> void:
	for i in range(order, block):
		var sum := 0
		for j in order:
			sum += coefs[j] * s[i - 1 - j]
		s[i] += sum >> shift


## The MD5 FLAC keeps: of each sample, little-endian, in as many bytes as its depth needs.
static func _md5(samples: PackedInt64Array, bits: int) -> PackedByteArray:
	var width := (bits + 7) / 8
	var raw := PackedByteArray()
	raw.resize(samples.size() * width)
	var at := 0
	match width:
		1:
			for v in samples:
				raw.encode_s8(at, v)
				at += 1
		2:
			for v in samples:
				raw.encode_s16(at, v)
				at += 2
		3:
			for v in samples:
				raw[at] = v & 0xFF
				raw[at + 1] = (v >> 8) & 0xFF
				raw[at + 2] = (v >> 16) & 0xFF
				at += 3
		_:
			for v in samples:
				raw.encode_s32(at, v)
				at += 4
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(raw)
	return h.finish()


## Reading a byte array a bit at a time, the most significant bit first.
class _Bits:
	var data: PackedByteArray
	var pos := 0
	## The bit past the last.
	var end := 0

	func _init(bytes: PackedByteArray, from_byte: int) -> void:
		data = bytes
		# Room to overrun by a few bytes on a damaged file without an index error.
		data.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]))
		pos = from_byte * 8
		end = bytes.size() * 8

	func align() -> void:
		pos = (pos + 7) & ~7

	func bits(n: int) -> int:
		var v := 0
		while n > 0:
			var index := pos >> 3
			if index >= data.size():
				pos += n
				return v << n
			var left := 8 - (pos & 7)
			var take := mini(left, n)
			v = (v << take) | ((data[index] >> (left - take)) & ((1 << take) - 1))
			pos += take
			n -= take
		return v

	func signed(n: int) -> int:
		if n <= 0:
			return 0
		var v := bits(n)
		return v - (1 << n) if v >= 1 << (n - 1) else v

	## Zeros before the next one, which is read too.
	func unary() -> int:
		var count := 0
		while true:
			var index := pos >> 3
			if index >= data.size():
				return count
			var off := pos & 7
			var byte := (data[index] << off) & 0xFF
			if byte == 0:
				count += 8 - off
				pos += 8 - off
				continue
			var lead := 0
			while byte & 0x80 == 0:
				byte <<= 1
				lead += 1
			count += lead
			pos += lead + 1
			return count
		return count

	## `count` Rice-coded values with parameter `k` into `out` from `at`. False past the end.
	## The hot loop of the whole decoder, so the bit reading is written out here, in locals.
	func rice(out: PackedInt64Array, at: int, count: int, k: int) -> bool:
		var d := data
		var p := pos
		var size := d.size()
		var low_mask := (1 << k) - 1
		for i in count:
			# The quotient: zeros up to the next one.
			var q := 0
			while true:
				var index := p >> 3
				if index >= size:
					pos = end + 1
					return false
				var off := p & 7
				var byte := (d[index] << off) & 0xFF
				if byte == 0:
					q += 8 - off
					p += 8 - off
					continue
				var lead := 0
				while byte < 0x80:
					byte <<= 1
					lead += 1
				q += lead
				p += lead + 1
				break
			# The remainder: k bits.
			var low := 0
			var n := k
			while n > 0:
				var index := p >> 3
				if index >= size:
					pos = end + 1
					return false
				var left := 8 - (p & 7)
				var take := left if left < n else n
				low = (low << take) | ((d[index] >> (left - take)) & ((1 << take) - 1))
				p += take
				n -= take
			var u := (q << k) | (low & low_mask)
			out[at + i] = (u >> 1) ^ -(u & 1)
		pos = p
		return p <= end
