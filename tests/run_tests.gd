extends SceneTree

## dawkit's own checks. Headless, no host application: `tools/test.sh`.

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_a_project_survives_its_plain_form()
	_test_every_field_is_in_the_plain_form()
	_test_a_difference_is_found_and_named()
	_test_a_looped_clip_plays_its_loop()
	_test_folders_route_to_their_parent()
	_test_broken_references_are_reported()
	_test_a_project_survives_a_dawproject_file()
	_test_the_file_is_valid_dawproject()
	_test_a_file_without_our_extras_still_opens()
	_test_a_bitwig_file_opens()
	_test_odd_names_survive_the_xml()
	_test_every_kind_of_wav_reads_the_same()
	_test_aiff_reads_the_same()
	_test_more_channels_fold_to_stereo()
	_test_a_file_is_brought_in_as_the_engine_plays_it()
	_test_ogg_and_mp3_are_decoded()
	_test_what_cannot_be_read_says_why()
	_test_the_click_is_on_the_beat()
	OS.execute("rm", ["-rf", OS.get_temp_dir().path_join("dawkit_tests_%d" % OS.get_process_id())])
	print("%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("FAIL  ", label)


## A small project with something in every field, so a field the plain form forgets shows up.
static func sample() -> DawKitProject:
	var p := DawKitProject.new()
	p.title = "Sample"
	p.tempo = 97.5
	p.time_signature = Vector2i(6, 8)
	p.length = 182.25
	p.metronome = true
	p.loop_on = true
	p.loop_start = 8.0
	p.loop_end = 16.5
	p.markers.append(DawKitMarker.new(0.0, "Intro"))
	var chorus := DawKitMarker.new(41.3, "Chorus")
	chorus.colour = Color(0.9, 0.4, 0.2)
	p.markers.append(chorus)
	p.master.volume_db = -1.5
	var drums := p.add_track("Drums")
	drums.colour = Color(0.78, 0.40, 0.32)
	var kick := p.add_track("Kick")
	kick.parent = drums.id
	kick.volume_db = -3.25
	kick.pan = -0.1
	kick.mute = true
	kick.monitor = DawKitTrack.Monitor.AUTO
	var eq := DawKitEffect.new()
	eq.kind = "eq6"
	eq.name = "EQ"
	eq.values.assign([0.5, 0.25, 0.75])
	eq.names.assign(["Low", "Mid", "High"])
	eq.wet = 0.8
	kick.effects.append(eq)
	var foreign := DawKitEffect.new()
	foreign.name = "Pro-Q 3"
	foreign.enabled = false
	foreign.plugin_format = "VST3"
	foreign.plugin_id = "72C4DB717A4D459AB97E51745D84B39D"
	foreign.state = PackedByteArray([1, 2, 3, 250])
	kick.effects.append(foreign)
	var keys := p.add_track("Keys")
	keys.armed = true
	var chords := DawKitClip.new()
	chords.start = 4.0
	chords.length = 8.0
	chords.name = "Chords"
	chords.notes = PackedFloat64Array([0.0, 0.5, 60, 100, 0, 0.5, 1.0, 64, 90, 1])
	keys.clips.append(chords)
	var verb := p.add_track("Verb")
	var send := DawKitSend.new()
	send.target = verb.id
	send.volume_db = -12.0
	send.pre_fader = true
	keys.sends.append(send)
	var take := DawKitClip.new()
	take.start = 12.125
	take.length = 3.5
	take.source = "audio/take1.wav"
	take.source_offset = 0.75
	take.fade_in = 0.01
	take.fade_out = 0.25
	take.gain_db = 2.5
	take.muted = true
	kick.clips.append(take)
	var loop := DawKitClip.new()
	loop.start = 20.0
	loop.length = 12.0
	loop.source = "audio/take1.wav"
	loop.loop_start = 0.0
	loop.loop_end = 2.0
	loop.source_offset = 0.5
	kick.clips.append(loop)
	return p


func _test_a_project_survives_its_plain_form() -> void:
	var p := sample()
	var back := DawKitProject.from_dict(p.to_dict())
	check("a project comes back from its plain form unchanged (%s)" % p.first_difference(back),
			p.same_as(back))
	var through_text := DawKitProject.from_dict(str_to_var(var_to_str(p.to_dict())))
	check("and through text (%s)" % p.first_difference(through_text), p.same_as(through_text))
	var through_json := DawKitProject.from_dict(JSON.parse_string(JSON.stringify(p.to_dict())))
	check("and through JSON (%s)" % p.first_difference(through_json), p.same_as(through_json))
	check("a copy is a copy", p.duplicate().same_as(p) and p.duplicate() != p)


func _test_every_field_is_in_the_plain_form() -> void:
	var p := sample()
	var back := DawKitProject.from_dict(p.to_dict())
	var kick := back.track("t2")
	check("folders by id", kick.parent == "t1")
	check("levels and pans", is_equal_approx(kick.volume_db, -3.25) and is_equal_approx(kick.pan, -0.1))
	check("monitor mode", kick.monitor == DawKitTrack.Monitor.AUTO)
	check("an engine effect keeps its kind and values",
			kick.effects[0].kind == "eq6" and Array(kick.effects[0].values) == [0.5, 0.25, 0.75])
	check("a foreign plugin keeps its id and its state, byte for byte",
			kick.effects[1].plugin_id.begins_with("72C4") and kick.effects[1].state == PackedByteArray([1, 2, 3, 250]))
	var take := kick.clips[0]
	check("an audio clip keeps its file, offset, fades and gain", take.source == "audio/take1.wav"
			and take.source_offset == 0.75 and take.fade_in == 0.01 and take.fade_out == 0.25
			and take.gain_db == 2.5 and take.muted)
	var chords := back.track("t3").clips[0]
	check("a MIDI clip keeps its notes (%d)" % chords.note_count(),
			chords.is_midi() and chords.note_count() == 2 and chords.notes[7] == 64.0)
	check("sends by id, pre-fader", back.track("t3").sends[0].target == "t4" and back.track("t3").sends[0].pre_fader)
	check("time signature, loop, markers", back.time_signature == Vector2i(6, 8) and back.loop_on
			and back.markers.size() == 2 and back.markers[1].name == "Chorus")
	check("the master is a track", back.master.id == "master" and back.master.volume_db == -1.5)


func _test_a_difference_is_found_and_named() -> void:
	var a := sample()
	var b := sample()
	b.track("t2").clips[0].fade_out = 0.3
	var said := a.first_difference(b)
	check("one changed fade is a difference (%s)" % said, not a.same_as(b))
	check("and is named by where it is", said.begins_with("tracks[1].clips[0].fade_out"))


func _test_a_looped_clip_plays_its_loop() -> void:
	var c := DawKitClip.new()
	c.length = 10.0
	c.source_offset = 0.5
	c.loop_end = 2.0
	check("a looped clip is looped", c.is_looped())
	check("it starts where its offset says", c.file_time(0.0) == 0.5)
	check("and comes round to the loop's start", is_equal_approx(c.file_time(1.5), 0.0) and is_equal_approx(c.file_time(2.25), 0.75))
	c.loop_end = 0.0
	check("an unlooped clip runs on through the file", c.file_time(3.0) == 3.5)


func _test_folders_route_to_their_parent() -> void:
	var p := sample()
	check("a track in a folder plays into the folder", p.output_of(p.track("t2")) == p.track("t1"))
	check("a top-level track plays into the master", p.output_of(p.track("t3")) == p.master)
	check("the master plays into nothing", p.output_of(p.master) == null)
	check("a folder knows its children", p.children_of("t1").size() == 1)


func _test_broken_references_are_reported() -> void:
	check("a sound project has no problems (%s)" % [sample().problems()], sample().problems().is_empty())
	var p := sample()
	p.track("t3").sends[0].target = "t99"
	p.track("t1").parent = "t2"
	var said := p.problems()
	check("a send to nowhere is found (%s)" % [said], "t3 sends to t99, which it cannot" in said)
	check("and a folder loop, from both sides", "t1 is inside itself" in said and "t2 is inside itself" in said)


func _tmp(name: String) -> String:
	var dir := OS.get_temp_dir().path_join("dawkit_tests_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(name)


## A real WAV in a media folder, so an audio clip has a file to carry.
func _media_root() -> String:
	var root := _tmp("media")
	DirAccess.make_dir_recursive_absolute(root.path_join("audio"))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = 48000
	var data := PackedByteArray()
	data.resize(48000 * 4 * 2)
	wav.data = data
	wav.save_to_wav(root.path_join("audio/take1.wav"))
	return root


func _test_a_project_survives_a_dawproject_file() -> void:
	var p := sample()
	var file := _tmp("sample.dawproject")
	var warnings := DawKitDawproject.save(p, file, _media_root())
	check("it saves without complaint (%s)" % [warnings], warnings.is_empty())
	var opened := DawKitDawproject.open(file, _tmp("opened"))
	check("it opens (%s)" % opened["error"], opened["project"] != null)
	if opened["project"] == null:
		return
	var back: DawKitProject = opened["project"]
	check("and is the same project (%s)" % p.first_difference(back), p.same_as(back))
	check("with nothing to say about it (%s)" % [opened["warnings"]], (opened["warnings"] as PackedStringArray).is_empty())
	check("and the audio file came out beside it",
			FileAccess.file_exists(_tmp("opened").path_join("audio/take1.wav")))
	var info := DawKitDawproject.wav_info(FileAccess.get_file_as_bytes(_tmp("opened").path_join("audio/take1.wav")))
	check("whole (%s)" % [info], info.get("rate") == 48000 and info.get("channels") == 2 and is_equal_approx(info.get("seconds", 0.0), 2.0))
	var again := _tmp("again.dawproject")
	DawKitDawproject.save(back, again, _tmp("opened"))
	var twice: DawKitProject = DawKitDawproject.open(again, _tmp("opened2"))["project"]
	check("saved and opened twice it is still the same", twice != null and p.same_as(twice))


func _test_the_file_is_valid_dawproject() -> void:
	if OS.execute("sh", ["-c", "command -v xmllint"]) != 0:
		print("SKIP  xmllint is not installed: the schema check did not run")
		return
	var file := _tmp("valid.dawproject")
	DawKitDawproject.save(sample(), file, _media_root())
	var zip := ZIPReader.new()
	zip.open(file)
	var out := _tmp("valid")
	DirAccess.make_dir_recursive_absolute(out)
	for entry in ["project.xml", "metadata.xml"]:
		FileAccess.open(out.path_join(entry), FileAccess.WRITE).store_buffer(zip.read_file(entry))
	check("plug-in state is stored as a file in the zip",
			Array(zip.get_files()).any(func(f): return f.begins_with("plugins/")))
	zip.close()
	var schemas := ProjectSettings.globalize_path("res://tests/fixtures/dawproject")
	for pair in [["project.xml", "Project.xsd"], ["metadata.xml", "MetaData.xsd"]]:
		var said: Array = []
		var rc := OS.execute("xmllint", ["--noout", "--schema", schemas.path_join(pair[1]),
				out.path_join(pair[0])], said, true)
		check("%s is valid against the official %s (%s)" % [pair[0], pair[1],
				str(said).substr(0, 400)], rc == 0)


## What another DAW leaves of a file it re-saves: project.xml without our extras.
func _without_extras(from: String, to: String) -> void:
	var r := ZIPReader.new()
	r.open(from)
	var w := ZIPPacker.new()
	w.open(to)
	for entry in r.get_files():
		if entry == DawKitDawproject.EXTRAS:
			continue
		w.start_file(entry)
		w.write_file(r.read_file(entry))
		w.close_file()
	w.close()
	r.close()


func _test_a_file_without_our_extras_still_opens() -> void:
	var p := sample()
	var file := _tmp("plain_src.dawproject")
	DawKitDawproject.save(p, file, _media_root())
	var plain := _tmp("plain.dawproject")
	_without_extras(file, plain)
	var opened := DawKitDawproject.open(plain, _tmp("plain_media"))
	var back: DawKitProject = opened["project"]
	check("a file another DAW re-saved opens (%s)" % opened["error"], back != null)
	if back == null:
		return
	var kick := back.track("t2")
	check("its levels are close enough to hear no difference",
			absf(kick.volume_db - p.track("t2").volume_db) < 0.0001 and absf(kick.pan - p.track("t2").pan) < 0.0001)
	check("folders, sends, markers and notes are in the XML itself",
			kick.parent == "t1" and back.track("t3").sends.size() == 1 and back.markers.size() == 2
			and back.track("t3").clips[0].note_count() == 2)
	check("an effect of ours is still ours", kick.effects[0].kind == "eq6"
			and Array(kick.effects[0].values) == [0.5, 0.25, 0.75])
	check("a foreign plugin's state is still byte for byte",
			kick.effects[1].plugin_format == "VST3" and kick.effects[1].state == PackedByteArray([1, 2, 3, 250]))
	check("fades and the file offset are in the XML", kick.clips[0].fade_out == 0.25
			and kick.clips[0].source_offset == 0.75 and kick.clips[0].muted)
	check("what only the extras held is gone, and nothing else",
			not back.loop_on and not back.track("t3").armed and kick.clips[0].gain_db == 0.0
			and kick.effects[0].wet == 1.0)


func _test_a_bitwig_file_opens() -> void:
	var xml := FileAccess.get_file_as_bytes("res://tests/fixtures/dawproject/bitwig_readme_example.xml")
	var file := _tmp("bitwig.dawproject")
	var w := ZIPPacker.new()
	w.open(file)
	w.start_file("project.xml")
	w.write_file(xml)
	w.close_file()
	w.close()
	var opened := DawKitDawproject.open(file, _tmp("bitwig_media"))
	var p: DawKitProject = opened["project"]
	check("Bitwig's own example opens (%s)" % opened["error"], p != null)
	if p == null:
		return
	check("at its tempo, 149", p.tempo == 149.0)
	check("with its two tracks and a master (%d)" % p.tracks.size(), p.tracks.size() == 2
			and p.tracks[0].name == "Bass" and p.tracks[1].name == "Drumloop" and p.master.name == "Master")
	var bass := p.tracks[0]
	check("the bass clip's nine notes (%d)" % (bass.clips[0].note_count() if not bass.clips.is_empty() else -1),
			bass.clips.size() == 1 and bass.clips[0].note_count() == 9)
	var beat := 60.0 / 149.0
	check("eight beats long, in seconds (%.4f)" % bass.clips[0].length, absf(bass.clips[0].length - 8.0 * beat) < 0.000001)
	check("its plug-in kept as a CLAP plug-in", bass.effects.size() == 1
			and bass.effects[0].plugin_format == "CLAP" and bass.effects[0].plugin_id == "org.surge-synth-team.surge-xt")
	var loop := p.tracks[1]
	check("the drum loop's audio event, from inside its clip (%d)" % loop.clips.size(),
			loop.clips.size() == 1 and loop.clips[0].source == "audio/Drumfunk3 170bpm.wav")
	close("its level, from a linear gain", loop.volume_db, linear_to_db(0.177125))
	check("and it says the audio itself is not in the file",
			(opened["warnings"] as PackedStringArray).size() == 1)


func _test_odd_names_survive_the_xml() -> void:
	var p := sample()
	p.title = "Rock & Roll <live>"
	p.track("t2").name = 'Kick "In" & <Out>'
	p.markers[0].name = "Bridge & Outro"
	var file := _tmp("odd.dawproject")
	DawKitDawproject.save(p, file, _media_root())
	var back: DawKitProject = DawKitDawproject.open(file, _tmp("odd_media"))["project"]
	check("names with &, <, > and quotes come back (%s)" % (p.first_difference(back) if back else "did not open"),
			back != null and p.same_as(back))


func close(label: String, a: float, b: float, epsilon := 0.0001) -> void:
	check("%s (%f vs %f)" % [label, a, b], absf(a - b) <= epsilon)


# --- audio files --------------------------------------------------------------------------

## A test sound: a 441 Hz sine at half scale, the right channel a quarter cycle on.
static func _tone(frames: int, channels: int, rate: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for f in frames:
		for c in channels:
			out.append(0.5 * sin(TAU * 441.0 * f / rate + c * PI * 0.5))
	return out


## Samples as the bytes of one encoding; `big` for AIFF.
static func _encode(samples: PackedFloat32Array, bits: int, floating: bool, big := false,
		signed_8 := false) -> PackedByteArray:
	var out := PackedByteArray()
	var width := bits / 8
	out.resize(samples.size() * width)
	for i in samples.size():
		var v := samples[i]
		var at := i * width
		if floating:
			if bits == 32: out.encode_float(at, v)
			else: out.encode_double(at, v)
		else:
			match bits:
				8:
					var q := clampi(int(round(v * 128.0)), -128, 127)
					out[at] = (q & 0xFF) if signed_8 else q + 128
				16: out.encode_s16(at, clampi(int(round(v * 32768.0)), -32768, 32767))
				24:
					var q := clampi(int(round(v * 8388608.0)), -8388608, 8388607) & 0xFFFFFF
					out[at] = q & 0xFF; out[at + 1] = (q >> 8) & 0xFF; out[at + 2] = q >> 16
				32: out.encode_s32(at, clampi(int(round(v * 2147483648.0)), -2147483648, 2147483647))
		if big:
			var word := out.slice(at, at + width)
			for k in width:
				out[at + k] = word[width - 1 - k]
	return out


static func _wav(samples: PackedFloat32Array, channels: int, rate: int, bits: int, floating: bool,
		extensible: bool) -> PackedByteArray:
	var data := _encode(samples, bits, floating)
	var fmt := PackedByteArray()
	fmt.resize(40 if extensible else 16)
	var tag := 3 if floating else 1
	fmt.encode_u16(0, 0xFFFE if extensible else tag)
	fmt.encode_u16(2, channels)
	fmt.encode_u32(4, rate)
	fmt.encode_u32(8, rate * channels * bits / 8)
	fmt.encode_u16(12, channels * bits / 8)
	fmt.encode_u16(14, bits)
	if extensible:
		fmt.encode_u16(16, 22)
		fmt.encode_u16(18, bits)
		fmt.encode_u32(20, 0)
		fmt.encode_u16(24, tag)
	var out := "RIFF".to_ascii_buffer()
	var size := PackedByteArray(); size.resize(4); size.encode_u32(0, 4 + 8 + fmt.size() + 8 + data.size())
	out.append_array(size)
	out.append_array("WAVEfmt ".to_ascii_buffer())
	var n := PackedByteArray(); n.resize(4); n.encode_u32(0, fmt.size()); out.append_array(n)
	out.append_array(fmt)
	# A chunk the reader has to step over.
	out.append_array("LIST".to_ascii_buffer())
	n.encode_u32(0, 3); out.append_array(n); out.append_array(PackedByteArray([1, 2, 3, 0]))
	out.append_array("data".to_ascii_buffer())
	n.encode_u32(0, data.size()); out.append_array(n)
	out.append_array(data)
	return out


static func _be32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


## An AIFF (or AIFF-C of `kind`) at 44100 Hz.
static func _aiff(samples: PackedFloat32Array, channels: int, bits: int, kind := "") -> PackedByteArray:
	var floating := kind == "fl32"
	var little := kind == "sowt"
	var data := _encode(samples, bits, floating, not little, true)
	var comm := PackedByteArray([0, channels])
	comm.append_array(_be32(samples.size() / channels))
	comm.append_array(PackedByteArray([0, bits]))
	# 44100 as an 80-bit extended float.
	comm.append_array(PackedByteArray([0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0]))
	if kind != "":
		comm.append_array(kind.to_ascii_buffer())
		comm.append_array(PackedByteArray([0, 0]))
	var body := ("AIFC" if kind != "" else "AIFF").to_ascii_buffer()
	body.append_array("COMM".to_ascii_buffer()); body.append_array(_be32(comm.size())); body.append_array(comm)
	body.append_array("SSND".to_ascii_buffer()); body.append_array(_be32(data.size() + 8))
	body.append_array(_be32(0)); body.append_array(_be32(0)); body.append_array(data)
	var out := "FORM".to_ascii_buffer()
	out.append_array(_be32(body.size()))
	out.append_array(body)
	return out


func _write(name: String, bytes: PackedByteArray) -> String:
	var path := _tmp(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	return path


## The largest difference between two sample runs, or 1 when their lengths differ.
static func _worst(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return 1.0
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _test_every_kind_of_wav_reads_the_same() -> void:
	var tone := _tone(4410, 2, 44100)
	for spec in [[8, false, false, 1.0 / 128.0], [16, false, false, 1.0 / 32768.0],
			[24, false, true, 1.0 / 8388608.0], [32, false, true, 1e-7], [32, true, false, 0.0],
			[64, true, false, 1e-7], [24, false, false, 1.0 / 8388608.0], [16, false, true, 1.0 / 32768.0]]:
		var label := "%d-bit %s%s" % [spec[0], "float" if spec[1] else "integer", " extensible" if spec[2] else ""]
		var path := _write("w%d_%s_%s.wav" % spec.slice(0, 3), _wav(tone, 2, 44100, spec[0], spec[1], spec[2]))
		var got := DawKitAudioFile.read(path)
		check("a %s WAV reads (%s)" % [label, got["error"]], got["error"] == "" and got["rate"] == 44100
				and got["channels"] == 2 and got["frames"] == 4410)
		var worst := _worst(got["samples"], tone)
		check("as the same sound, to its last bit (%s: off by %.9f)" % [label, worst], worst <= spec[3] + 1e-7)
	var mono := _tone(100, 1, 22050)
	var got := DawKitAudioFile.read(_write("mono.wav", _wav(mono, 1, 22050, 16, false, false)))
	check("a mono WAV stays mono, at its own rate", got["channels"] == 1 and got["rate"] == 22050 and got["frames"] == 100)


func _test_aiff_reads_the_same() -> void:
	var tone := _tone(2000, 2, 44100)
	for spec in [[16, "", 1.0 / 32768.0], [24, "", 1.0 / 8388608.0], [8, "", 1.0 / 128.0],
			[16, "sowt", 1.0 / 32768.0], [16, "NONE", 1.0 / 32768.0], [32, "fl32", 0.0]]:
		var got := DawKitAudioFile.read(_write("a%d%s.aif" % [spec[0], spec[1]], _aiff(tone, 2, spec[0], spec[1])))
		var label := "%d-bit AIFF%s" % [spec[0], ("-C " + spec[1]) if spec[1] != "" else ""]
		check("a %s reads at 44100 Hz (%s %s)" % [label, got["error"], got["rate"]],
				got["error"] == "" and got["rate"] == 44100 and got["frames"] == 2000)
		var worst := _worst(got["samples"], tone)
		check("as the same sound (%s: off by %.9f)" % [label, worst], worst <= spec[2] + 1e-7)


func _test_more_channels_fold_to_stereo() -> void:
	var six := PackedFloat32Array()
	for f in 10:
		six.append_array([0.6, 0.3, 0.0, 0.3, 0.0, 0.3])
	var got := DawKitAudioFile.read(_write("six.wav", _wav(six, 6, 48000, 32, true, true)))
	var s: PackedFloat32Array = got["samples"]
	check("six channels arrive as two (%s)" % got["error"], got["channels"] == 2 and got["frames"] == 10)
	close("the odd ones on the left, averaged", s[0], 0.2)
	close("the even ones on the right", s[1], 0.3)


func _test_a_file_is_brought_in_as_the_engine_plays_it() -> void:
	var tone := _tone(44100, 2, 44100)
	var plain := _write("plain.wav", _wav(tone, 2, 44100, 16, false, false))
	var into := _tmp("brought/plain.wav")
	var done := DawKitAudioFile.bring_in(plain, into)
	check("a WAV the engine plays already is copied untouched (%s)" % done.get("error"),
			done.get("error") == "" and done["copied"]
			and FileAccess.get_file_as_bytes(into) == FileAccess.get_file_as_bytes(plain))
	close("it is a second long", done["seconds"], 1.0)
	var peaks: PackedByteArray = done["peaks"]
	check("with an overview fifty a second (%d)" % peaks.size(), peaks.size() == 50)
	check("as loud as the sound is: half scale (%d)" % peaks[10], absi(peaks[10] - 127) <= 1)

	var deep := _write("deep.wav", _wav(tone, 2, 44100, 24, false, true))
	var into24 := _tmp("brought/deep.wav")
	done = DawKitAudioFile.bring_in(deep, into24)
	check("a 24-bit extensible WAV is rewritten (%s)" % done.get("error"), done.get("error") == "" and not done["copied"])
	var played := AudioStreamWAV.load_from_file(into24)
	check("as a WAV the engine loads", played != null and played.stereo and played.mix_rate == 44100)
	var back := DawKitAudioFile.read(into24)
	var worst := _worst(back["samples"], DawKitAudioFile.read(deep)["samples"])
	check("losing nothing on the way (off by %.9f)" % worst, worst == 0.0)

	var silent := _write("empty.wav", _wav(PackedFloat32Array(), 2, 44100, 16, false, false))
	done = DawKitAudioFile.bring_in(silent, _tmp("brought/empty.wav"))
	check("a file with no sound is refused (%s)" % done.get("error"), str(done.get("error")).contains("no sound"))


## Measured: the frequency from the zero crossings, the level from the peak.
func _test_ogg_and_mp3_are_decoded() -> void:
	for name in ["sine440.ogg", "sine440.mp3"]:
		var path := ProjectSettings.globalize_path("res://tests/fixtures/audio/" + name)
		var got := DawKitAudioFile.read(path)
		check("%s decodes (%s)" % [name, got["error"]], got["error"] == "" and got["channels"] == 2)
		if got["error"] != "":
			continue
		var s: PackedFloat32Array = got["samples"]
		var rate := float(got["rate"])
		close("%s is half a second long" % name, got["frames"] / rate, 0.5, 0.06)
		var crossings := 0
		var loudest := 0.0
		var from := int(rate * 0.1)
		var to := int(rate * 0.4)
		for f in range(from, to):
			loudest = maxf(loudest, absf(s[f * 2]))
			if (s[f * 2] >= 0.0) != (s[(f - 1) * 2] >= 0.0):
				crossings += 1
		close("%s is 440 Hz" % name, crossings / 2.0 / ((to - from) / rate), 440.0, 6.0)
		close("%s is at half scale" % name, loudest, 0.5, 0.05)


func _test_what_cannot_be_read_says_why() -> void:
	var flac := _write("song.flac", "fLaC".to_ascii_buffer() + PackedByteArray([0, 0, 0, 0]))
	check("FLAC says it cannot be read yet", str(DawKitAudioFile.read(flac)["error"]).contains("FLAC"))
	var text := _write("notes.txt", "hello there".to_ascii_buffer())
	check("a file that is not sound says so", str(DawKitAudioFile.read(text)["error"]).contains("not a sound file"))
	var adpcm := _wav(_tone(10, 1, 8000), 1, 8000, 16, false, false)
	adpcm.encode_u16(20, 2)
	check("a compressed WAV says what to do",
			str(DawKitAudioFile.read(_write("adpcm.wav", adpcm))["error"]).contains("save it as PCM"))
	check("a missing file says so", str(DawKitAudioFile.read(_tmp("nope.wav"))["error"]).contains("could not be read"))


func _test_the_click_is_on_the_beat() -> void:
	var wav := DawKitMetronome.bar(120.0, 4, 48000)
	close("a bar at 120 in 4/4 is two seconds", wav.get_length(), 2.0)
	check("and loops whole", wav.loop_mode == AudioStreamWAV.LOOP_FORWARD and wav.loop_end == 96000)
	# Onsets: the first sample over a quarter of full scale after a silence.
	var onsets: Array[int] = []
	var quiet := 0
	for f in wav.data.size() / 4:
		var v := absi(wav.data.decode_s16(f * 4))
		if v > 8000 and quiet > 1000:
			onsets.append(f)
		quiet = 0 if v > 50 else quiet + 1
	if wav.data.decode_s16(0) > 8000:
		onsets.push_front(0)
	check("a click on each beat, to the sample (%s)" % [onsets], onsets == [0, 24000, 48000, 72000])
	check("the first beat is the loud one", wav.data.decode_s16(0) > wav.data.decode_s16(24000 * 4))
	close("3/4 at 90 is two seconds too", DawKitMetronome.bar_seconds(90.0, 3), 2.0)
