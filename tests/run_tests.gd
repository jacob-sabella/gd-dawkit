extends SceneTree

## dawkit's own checks. Headless, no host application: `tools/test.sh`.

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_a_project_survives_its_plain_form()
	_test_every_field_is_in_the_plain_form()
	_test_a_difference_is_found_and_named()
	_test_a_looped_clip_plays_its_loop()
	_test_a_comp_picks_which_take_sounds()
	_test_a_clip_keeps_controller_and_pitch_bend_lanes()
	_test_a_frozen_track_can_be_thawed_and_is_saved()
	_test_folders_route_to_their_parent()
	_test_broken_references_are_reported()
	_test_a_project_survives_a_dawproject_file()
	_test_the_file_is_valid_dawproject()
	_test_a_file_without_our_extras_still_opens()
	_test_a_bitwig_file_opens()
	_test_odd_names_survive_the_xml()
	_test_every_kind_of_wav_reads_the_same()
	_test_aiff_reads_the_same()
	_test_a_wav_is_written_at_its_depth()
	_test_more_channels_fold_to_stereo()
	_test_a_file_is_brought_in_as_the_engine_plays_it()
	_test_ogg_and_mp3_are_decoded()
	_test_flac_decodes_to_its_last_bit()
	_test_lanes_play_on_the_same_sample()
	_test_what_cannot_be_read_says_why()
	_test_the_click_is_on_the_beat()
	_test_the_instrument_plays_each_note_on_its_sample()
	_test_an_instrument_is_an_instrument_in_the_file()
	_test_the_tempo_map_counts_beats_into_seconds()
	_test_a_file_with_tempo_changes_opens_where_it_sounds()
	_test_a_tempo_map_survives_the_file()
	_test_the_click_follows_the_tempo_map()
	_test_the_meter_counts_bars()
	_test_time_signature_changes_survive_the_file()
	_test_automation_is_read_along_the_song()
	_test_automation_survives_the_file_without_our_extras()
	_test_the_official_examples_open_and_come_back()
	_test_plugins_are_found_and_described()
	_test_a_plugin_effect_changes_the_sound()
	_test_a_plugins_state_comes_back()
	_test_an_instrument_plugin_plays_live_notes()
	_test_a_lane_plays_its_notes_through_its_instrument()
	_test_a_plugin_effect_runs_once_for_every_bus_it_is_on()
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
	p.regions.append(DawKitRegion.new(41.3, 60.75, "Chorus 1"))
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
	keys.input = "midi"
	keys.group = 2
	var tine := DawKitEffect.new()
	tine.kind = "tine"
	tine.name = "Tine"
	tine.instrument = true
	keys.effects.append(tine)
	var chords := DawKitClip.new()
	chords.start = 4.0
	chords.length = 8.0
	chords.name = "Chords"
	chords.notes = PackedFloat64Array([0.0, 0.5, 60, 100, 0, 0.5, 1.0, 64, 90, 1])
	chords.controls = PackedFloat64Array([0.0, 1, 0, 0, 0.25, 1, 64, 0, 0.5, 128, -4096.5, 1, 0.75, 129, 90, 0])
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
	take.reversed = true
	take.locked = true
	take.lane = 1
	take.fade_shape = DawKitClip.FADE_EQUAL_POWER
	take.fade_out_shape = DawKitClip.FADE_S_CURVE
	kick.clips.append(take)
	kick.comp = [[12.125, 13.5, 1], [13.5, 40.0, 0]]
	var loop := DawKitClip.new()
	loop.start = 20.0
	loop.length = 12.0
	loop.source = "audio/take1.wav"
	loop.loop_start = 0.0
	loop.loop_end = 2.0
	loop.source_offset = 0.5
	kick.clips.append(loop)
	# A ride on every kind of control.
	kick.automation.append(DawKitAutomation.new("volume", [[0.0, -3.25, 1], [4.0, -12.0, 1], [8.0, 0.0, 0]]))
	kick.automation.append(DawKitAutomation.new("pan", [[2.0, -0.5, 1], [6.0, 0.5, 0]]))
	kick.automation.append(DawKitAutomation.new("mute", [[10.0, 1.0, 0], [11.0, 0.0, 0]]))
	kick.automation.append(DawKitAutomation.new("fx:0:1", [[1.0, 0.25, 1], [3.0, 0.75, 1]]))
	keys.automation.append(DawKitAutomation.new("send:" + verb.id, [[0.0, -24.0, 1], [16.0, -6.0, 0]]))
	p.master.automation.append(DawKitAutomation.new("volume", [[170.0, -1.5, 1], [182.0, -60.0, 0]]))
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
			and take.gain_db == 2.5 and take.muted and take.reversed and take.locked
			and take.fade_shape == DawKitClip.FADE_EQUAL_POWER and take.fade_out_shape == DawKitClip.FADE_S_CURVE)
	check("a clip written with one shape has it at both ends",
			DawKitClip.from_dict({"fade_shape": 1}).fade_out_shape == DawKitClip.FADE_EQUAL_POWER
			and DawKitClip.from_dict({"fade_shape": 9}).fade_shape == DawKitClip.FADE_LINEAR)
	check("the shapes, halfway", is_equal_approx(DawKitClip.fade_gain(0.5, DawKitClip.FADE_SLOW), 0.25)
			and is_equal_approx(DawKitClip.fade_gain(0.5, DawKitClip.FADE_FAST), 0.75)
			and is_equal_approx(DawKitClip.fade_gain(0.5, DawKitClip.FADE_S_CURVE), 0.5)
			and is_equal_approx(DawKitClip.fade_gain(0.25, DawKitClip.FADE_S_CURVE), 0.5 - 0.5 * cos(PI / 4.0))
			and is_equal_approx(DawKitClip.fade_gain(0.5, DawKitClip.FADE_LINEAR), 0.5))
	var chords := back.track("t3").clips[0]
	check("a MIDI clip keeps its notes (%d)" % chords.note_count(),
			chords.is_midi() and chords.note_count() == 2 and chords.notes[7] == 64.0)
	check("the track's input (%s)" % back.track("t3").input, back.track("t3").input == "midi" and kick.input == "")
	check("the track's group (%d)" % back.track("t3").group, back.track("t3").group == 2 and kick.group == 0)
	check("sends by id, pre-fader", back.track("t3").sends[0].target == "t4" and back.track("t3").sends[0].pre_fader)
	check("time signature, loop, markers", back.time_signature == Vector2i(6, 8) and back.loop_on
			and back.markers.size() == 2 and back.markers[1].name == "Chorus")
	check("regions", back.regions.size() == 1 and back.regions[0].name == "Chorus 1"
			and back.regions[0].start == 41.3 and back.regions[0].end == 60.75)
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
			not back.loop_on and not back.track("t3").armed and back.track("t3").input == "" and back.track("t3").group == 0
			and kick.clips[0].gain_db == 0.0
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
	var said: PackedStringArray = opened["warnings"]
	check("and it says what it could not carry: the stretch, the audio, the synth's state (%s)" % said,
			said.size() == 3 and "88%" in said[0] and "Drumfunk3" in said[1] and "Surge XT" in said[2])


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


func _test_a_wav_is_written_at_its_depth() -> void:
	var tone := _tone(4410, 2, 44100)
	for spec in [[16, 1.0 / 32768.0], [24, 1.0 / 8388608.0], [32, 0.0]]:
		var path := _tmp("written%d.wav" % spec[0])
		check("a %d-bit WAV is written" % spec[0], DawKitAudioFile.write_wav(path, tone, 2, 44100, spec[0]) == OK)
		var bytes := FileAccess.get_file_as_bytes(path)
		check("at %d bits, %s" % [spec[0], "float" if spec[0] == 32 else "integer"],
				bytes.decode_u16(34) == spec[0] and bytes.decode_u16(20) == (3 if spec[0] == 32 else 1))
		var got := DawKitAudioFile.read(path)
		var worst := _worst(got["samples"], tone)
		# Dither and rounding: at most two steps off.
		check("and reads back as the same sound (%d-bit: off by %.9f)" % [spec[0], worst],
				got["error"] == "" and got["frames"] == 4410 and worst <= spec[1] * 2.0 + 1e-7)
	var quiet := PackedFloat32Array()
	quiet.resize(2000)
	quiet.fill(0.25 / 32768.0)
	var path := _tmp("dither.wav")
	DawKitAudioFile.write_wav(path, quiet, 1, 44100, 16)
	var got: PackedFloat32Array = DawKitAudioFile.read(path)["samples"]
	var mean := 0.0
	var distinct := {}
	for v in got:
		mean += v
		distinct[v] = true
	mean /= got.size()
	check("a level under one step is dithered, not rounded away (mean %.3f steps, %d values)" % [mean * 32768.0, distinct.size()],
			distinct.size() > 1 and absf(mean * 32768.0 - 0.25) < 0.1)
	DawKitAudioFile.write_wav(_tmp("again.wav"), quiet, 1, 44100, 16)
	check("and the same sound writes the same file", FileAccess.get_file_as_bytes(path)
			== FileAccess.get_file_as_bytes(_tmp("again.wav")))


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


## Each fixture was encoded by the reference `flac` 1.5 from the WAV beside it -- a tone, a burst
## of noise, silence and a square, so every subframe kind turns up -- at settings that reach the
## format's corners: fixed predictors (-0), LPC to order 32 with exhaustive model search and every
## stereo mode (-8 -e -p -m -l 32 --lax), 192-sample blocks, 8, 16, 24 and 32 bits, wasted bits
## (a 24-bit file of 16-bit sound), and six channels.
func _test_flac_decodes_to_its_last_bit() -> void:
	var dir := "res://tests/fixtures/audio/flac/"
	for spec in [["s16_stereo_8", "s16_stereo"], ["s16_stereo_0", "s16_stereo"], ["s16_stereo_lax", "s16_stereo"],
			["s24_stereo_5", "s24_stereo"], ["s24_stereo_8", "s24_stereo"], ["s16_mono_0", "s16_mono"],
			["s16_mono_192", "s16_mono"], ["s8_mono", "s8_mono"], ["s16_six", "s16_six"],
			["s24_wasted", "s24_wasted"], ["s32_stereo", "s32_stereo"]]:
		var got := DawKitAudioFile.read(ProjectSettings.globalize_path(dir + spec[0] + ".flac"))
		var want := DawKitAudioFile.read(ProjectSettings.globalize_path(dir + spec[1] + ".wav"))
		check("%s decodes (%s)" % [spec[0], got["error"]], got["error"] == "" and want["error"] == ""
				and got["rate"] == want["rate"] and got["channels"] == want["channels"] and got["frames"] == want["frames"])
		var worst := _worst(got["samples"], want["samples"])
		check("to exactly the sound encoded (%s: off by %.9f)" % [spec[0], worst], worst == 0.0)

	var whole := FileAccess.get_file_as_bytes(dir + "s16_stereo_8.flac")
	var raw := DawKitFlac.decode_ints(whole)
	var ints: PackedInt64Array = raw["samples"]
	check("the integers come out as the file holds them (%d bits, %d)" % [raw["bits"], ints[1000 * 2]],
			raw["bits"] == 16 and absi(ints[1000 * 2]) < 32768)
	var bent := whole.duplicate()
	bent[bent.size() / 2] ^= 0x10
	var broken := DawKitAudioFile.read(_write("bent.flac", bent))
	check("one bit changed is caught (%s)" % broken["error"], broken["error"] != "")
	var cut := DawKitAudioFile.read(_write("cut.flac", whole.slice(0, whole.size() / 2)))
	check("a file cut short says so (%s)" % cut["error"], str(cut["error"]).contains("short"))
	var started := Time.get_ticks_msec()
	DawKitAudioFile.read(ProjectSettings.globalize_path(dir + "s24_stereo_8.flac"))
	var ms := Time.get_ticks_msec() - started
	print("flac: 9000 frames of 24-bit stereo in %d ms" % ms)


## The native core (native/, a GDExtension): lanes sharing a transport, mixed a block at a time in
## whatever order, as Godot's audio server mixes them.
func _test_lanes_play_on_the_same_sample() -> void:
	if not ClassDB.class_exists(&"DawKitTransport"):
		check("the native core is built and loaded (tools/build_native.sh)", false)
		return
	var t = ClassDB.instantiate(&"DawKitTransport")
	t.set_rate(48000)
	var click := PackedFloat32Array()
	click.resize(2 * 4800)
	click[0] = 1.0
	click[1] = 1.0
	var lane := func(clips: Array) -> Object:
		var l = ClassDB.instantiate(&"DawKitLane")
		l.set_transport(t)
		l.set_clips(clips)
		return l
	var a = lane.call([{"id": 1, "samples": click, "channels": 2, "rate": 48000, "start": 0.5, "length": 0.1}])
	var b = lane.call([{"id": 1, "samples": click, "channels": 2, "rate": 48000, "start": 0.5, "length": 0.1}])
	var pa = a.instantiate_playback()
	var pb = b.instantiate_playback()
	var out_a := PackedVector2Array()
	var out_b := PackedVector2Array()
	# Idle a few blocks, then the song starts at 0.4 s, 0.01 s from the clock's last block.
	for k in 3:
		out_a.append_array(pa.mix_audio(1.0, 512))
		out_b.append_array(pb.mix_audio(1.0, 512))
	t.play_from(0.4, 0.01)
	var started: int = t.get_anchor_clock()
	var pc = null
	var out_c := PackedVector2Array()
	for k in 20:
		if k == 5:
			# A lane that joins late, mixed first in its first block.
			var c = lane.call([{"id": 1, "samples": click, "channels": 2, "rate": 48000, "start": 0.5, "length": 0.1}])
			pc = c.instantiate_playback()
			out_c.resize(out_a.size())
		var order := [pa, pb] if k % 2 == 0 else [pb, pa]
		if pc != null:
			order.push_front(pc)
		for p in order:
			var got: PackedVector2Array = p.mix_audio(1.0, 512)
			if p == pa:
				out_a.append_array(got)
			elif p == pb:
				out_b.append_array(got)
			else:
				out_c.append_array(got)
	var first := func(frames: PackedVector2Array) -> int:
		for i in frames.size():
			if frames[i].x > 0.5:
				return i
		return -1
	var expected := started + int(0.1 * 48000)
	check("two lanes sound a clip on the same sample, whichever is mixed first (%d, %d, wanted %d)" % [
			first.call(out_a), first.call(out_b), expected], first.call(out_a) == expected and first.call(out_b) == expected)
	check("and so does one that joined later (%d)" % first.call(out_c), first.call(out_c) == expected)
	close("the song is where the lanes have got to", t.song_seconds(), 0.4 + (23 * 512 - started) / 48000.0, 0.0001)

	# A fade, as a curve, and gain.
	var dc := PackedFloat32Array()
	dc.resize(48000)
	dc.fill(1.0)
	t.stop()
	var f = lane.call([{"id": 2, "samples": dc, "channels": 1, "rate": 48000, "start": 0.0, "length": 1.0,
			"gain": 0.5, "fade_in": 0.1, "fade_out": 0.1, "fade_shape": 1, "fade_out_shape": 2}])
	var base_f: int = t.get_clock()
	var pf = f.instantiate_playback()
	t.play_from(0.0, 0.0)
	var faded := PackedVector2Array()
	for k in 100:
		faded.append_array(pf.mix_audio(1.0, 480))
	# Indices from when this lane began: the clock had run on before it.
	var at0: int = t.get_anchor_clock() - base_f
	close("a fade in starts from nothing", faded[at0].x, 0.0, 0.0001)
	close("halfway through an equal-power fade it is at sin(45 deg)", faded[at0 + 2400].x, 0.5 * sin(PI / 4.0), 0.0005)
	close("past it, the gain", faded[at0 + 24000].x, 0.5, 0.0001)
	close("the fade out ends at nothing", faded[at0 + 47999].x, 0.0, 0.0001)
	close("and is its own shape: slow, a square, halfway through it", faded[at0 + 47999 - 2400].x, 0.5 * 0.25, 0.0005)
	check("mono plays on both sides", is_equal_approx(faded[at0 + 24000].x, faded[at0 + 24000].y))

	# A sound at another rate plays at its own speed; a clip's offset and the transport's loop.
	var ramp := PackedFloat32Array()
	for i in 24000:
		ramp.append(i / 24000.0)
	t.stop()
	var g = lane.call([{"id": 3, "samples": ramp, "channels": 1, "rate": 24000, "start": 0.0, "length": 1.0, "offset": 0.25}])
	var base_g: int = t.get_clock()
	var pg = g.instantiate_playback()
	t.set_loop(0.0, 0.5, true)
	t.play_from(0.0, 0.0)
	var heard := PackedVector2Array()
	for k in 200:
		heard.append_array(pg.mix_audio(1.0, 480))
	var at1: int = t.get_anchor_clock() - base_g
	close("a 24 kHz sound is read at its own speed, from its offset", heard[at1 + 12000].x, 0.5, 0.0001)
	close("and the song loops round its range", heard[at1 + 24000 + 12000].x, 0.5, 0.0001)
	t.set_loop(0.0, 0.0, false)
	t.stop()
	g.set_clips([{"id": 3, "start": 0.0, "length": 0.5}])
	check("a sound given before is kept by its id, not sent again", g.clip_count() == 1)

	# A 16-bit stream as Godot holds one, decoded here; and a count-in's hold, which the click
	# (a lane not held) plays through.
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = 48000
	var pcm := PackedByteArray()
	pcm.resize(48000 * 4)
	for i in 48000:
		pcm.encode_s16(i * 4, 16384)
		pcm.encode_s16(i * 4 + 2, -8192)
	wav.data = pcm
	var song = lane.call([{"id": 4, "wav": wav, "start": 0.0, "length": 1.0}])
	var clicks = lane.call([{"id": 5, "wav": wav, "start": 0.0, "length": 1.0}])
	clicks.set_held(false)
	var base_h: int = t.get_clock()
	var ps = song.instantiate_playback()
	var pk = clicks.instantiate_playback()
	t.set_hold(0.5)
	t.play_from(0.0, 0.0)
	var s_out := PackedVector2Array()
	var k_out := PackedVector2Array()
	for k in 100:
		s_out.append_array(ps.mix_audio(1.0, 480))
		k_out.append_array(pk.mix_audio(1.0, 480))
	var at2: int = t.get_anchor_clock() - base_h
	close("a 16-bit stream plays as the values it holds (left)", s_out[at2 + 30000].x, 0.5, 0.0001)
	close("and right", s_out[at2 + 30000].y, -0.25, 0.0001)
	check("the song is held silent until the count-in's end (%f)" % s_out[at2 + 1000].x, s_out[at2 + 1000].x == 0.0
			and s_out[at2 + 23999].x == 0.0 and s_out[at2 + 24000].x > 0.4)
	check("while a lane not held plays through it", k_out[at2 + 1000].x > 0.4)
	t.set_hold(-1.0)
	t.stop()
	# A count-in from the song's top runs before it: a lane plays song time below 0.
	var early = lane.call([{"id": 6, "wav": wav, "start": -1.0, "length": 0.5}])
	var base_e: int = t.get_clock()
	var pe = early.instantiate_playback()
	t.play_from(-1.0, 0.0)
	var e_out := PackedVector2Array()
	for k in 20:
		e_out.append_array(pe.mix_audio(1.0, 480))
	check("before the song's start, a clip there sounds", e_out[t.get_anchor_clock() - base_e + 100].x > 0.4)
	t.stop()


func _test_what_cannot_be_read_says_why() -> void:
	var flac := _write("song.flac", "fLaC".to_ascii_buffer() + PackedByteArray([0, 0, 0, 0]))
	check("a FLAC file with nothing in it says so", str(DawKitAudioFile.read(flac)["error"]).contains("FLAC"))
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


static func _first_sound(frames: PackedVector2Array, threshold := 0.0) -> int:
	for i in frames.size():
		if absf(frames[i].x) > threshold or absf(frames[i].y) > threshold:
			return i
	return -1


static func _loudest(frames: PackedVector2Array, from: int, to: int) -> float:
	var top := 0.0
	for i in range(maxi(from, 0), mini(to, frames.size())):
		top = maxf(top, maxf(absf(frames[i].x), absf(frames[i].y)))
	return top


func _test_the_instrument_plays_each_note_on_its_sample() -> void:
	var one := PackedFloat64Array([0.4321, 0.9, 60, 100, 0])
	var heard := DawKitTine.render_notes(one, 2.0, 48000.0)
	check("a clip renders its length and a tail (%d)" % heard.size(),
			heard.size() == int(ceil((2.0 + DawKitTine.TAIL_SECONDS) * 48000.0)))
	# A voice starts at phase zero, so a note's first sample is a zero crossing: the first one
	# with any sound in it is the next.
	check("silence until the note, and the note on its own sample (%d)" % _first_sound(heard),
			_first_sound(heard) == int(round(0.4321 * 48000.0)) + 1)
	check("loud enough to hear (%.2f)" % _loudest(heard, 20000, 30000), _loudest(heard, 20000, 30000) > 0.1)
	check("let go, it is damped: quiet 0.4s on (%.4f)" % _loudest(heard, int(1.3 * 48000), int(1.4 * 48000)),
			_loudest(heard, int(1.3 * 48000), int(1.4 * 48000)) < 0.01)
	var two := PackedFloat64Array([0.4321, 0.9, 60, 100, 0, 0.61803, 1.2, 67, 80, 0])
	var both := DawKitTine.render_notes(two, 2.0, 48000.0)
	var diff := PackedVector2Array()
	diff.resize(both.size())
	for i in both.size():
		diff[i] = both[i] - heard[i]
	check("a second note starts on its own sample too (%d)" % _first_sound(diff, 1e-6),
			_first_sound(diff, 1e-6) == int(round(0.61803 * 48000.0)) + 1)
	var late := DawKitTine.render_notes(PackedFloat64Array([2.5, 3.0, 60, 100, 0]), 2.0)
	check("a note after the clip's end is not played", _first_sound(late) == -1)
	var held := DawKitTine.new()
	held.note_on(48, 127)
	held.render(4800)
	held.sustain(true)
	held.note_off(48)
	var ring := _loudest(held.render(48000), 40000, 48000)
	check("the pedal holds a let-go note (%.3f)" % ring, ring > 0.05)


func _test_an_instrument_is_an_instrument_in_the_file() -> void:
	var file := _tmp("instrument.dawproject")
	DawKitDawproject.save(sample(), file, _media_root())
	var zip := ZIPReader.new()
	zip.open(file)
	var xml := zip.read_file("project.xml").get_string_from_utf8()
	zip.close()
	check("the tine is written as a built-in instrument", xml.contains('deviceRole="instrument"')
			and xml.contains('deviceID="dawkit:tine"'))
	var bare := _tmp("instrument_bare.dawproject")
	_without_extras(file, bare)
	var back: DawKitProject = DawKitDawproject.open(bare, _tmp("instrument_media"))["project"]
	var keys := back.track("t3") if back != null else null
	check("and read back as one, from the XML alone", keys != null and not keys.effects.is_empty()
			and keys.effects[0].instrument and keys.effects[0].kind == "tine")


func _test_the_tempo_map_counts_beats_into_seconds() -> void:
	var m := DawKitTempoMap.new(120.0)
	check("one tempo is constant", m.is_constant())
	close("at 120, beat 4 is two seconds", m.seconds_at(4.0), 2.0)
	m.set_point(4.0, 60.0)
	close("held at 60 from beat 4, beat 6 is two seconds later", m.seconds_at(6.0), 4.0)
	close("and back again", m.beat_at(4.0), 6.0)
	close("before the change it is still 120", m.seconds_at(2.0), 1.0)
	close("the tempo is read where it holds", m.bpm_at(5.0), 60.0)
	var ramp := DawKitTempoMap.new(60.0)
	ramp.points[0][2] = DawKitTempoMap.RAMP_BEATS
	ramp.set_point(4.0, 120.0)
	ramp._index()
	close("a ramp's tempo is a straight line in beats", ramp.bpm_at(2.0), 90.0)
	# 60 -> 120 bpm over 4 beats: k = 15 bpm a beat, so (60 / 15) ln 2 seconds.
	close("and its seconds are the exact integral (%.6f)" % ramp.seconds_at(4.0), ramp.seconds_at(4.0), 4.0 * log(2.0), 0.000001)
	close("past it the last tempo holds", ramp.seconds_at(6.0), 4.0 * log(2.0) + 1.0, 0.000001)
	var round_trip := true
	for b in [0.0, 0.5, 1.7, 3.99, 4.0, 9.25]:
		round_trip = round_trip and absf(ramp.beat_at(ramp.seconds_at(b)) - b) < 0.000001
	check("seconds and beats are each other's inverse, across the ramp", round_trip)
	var back := DawKitTempoMap.from_array(ramp.to_array())
	close("and the map survives its plain form", back.seconds_at(4.0), ramp.seconds_at(4.0), 0.0000001)
	# Reaper's kind: 60 -> 120 bpm in a straight line over time, 4 beats taking 120*4/180 s.
	var timed := DawKitTempoMap.new(60.0, [[0.0, 60.0, DawKitTempoMap.RAMP_SECONDS], [4.0, 120.0]])
	close("a ramp in time covers its beats in 120 B / (T0 + T1) seconds", timed.seconds_at(4.0), 480.0 / 180.0, 0.000001)
	close("half way in time it is half way in tempo", timed.bpm_at(timed.beat_at(timed.seconds_at(4.0) * 0.5)), 90.0, 0.000001)
	var timed_round := true
	for b in [0.25, 1.0, 2.5, 3.999, 7.0]:
		timed_round = timed_round and absf(timed.beat_at(timed.seconds_at(b)) - b) < 0.000001
	check("and its seconds and beats are each other's inverse", timed_round)
	check("an older map's true is a ramp in beats", DawKitTempoMap.shape_of(true) == DawKitTempoMap.RAMP_BEATS)


## Bitwig's example, with the tempo halved at beat 4: the bass clip and its notes, given in beats,
## have to land where they sound.
func _test_a_file_with_tempo_changes_opens_where_it_sounds() -> void:
	var xml := FileAccess.get_file_as_string("res://tests/fixtures/dawproject/bitwig_readme_example.xml")
	for interpolation in ["hold", "linear"]:
		var points := '<TempoAutomation unit="bpm" id="tx"><Target parameter="id0"/>' \
				+ '<RealPoint time="0" value="149" interpolation="%s"/>' % interpolation \
				+ '<RealPoint time="4" value="74.5" interpolation="hold"/></TempoAutomation>'
		var changed := xml.replace("</Arrangement>", points + "</Arrangement>")
		var file := _tmp("tempo_%s.dawproject" % interpolation)
		var w := ZIPPacker.new()
		w.open(file)
		w.start_file("project.xml")
		w.write_file(changed.to_utf8_buffer())
		w.close_file()
		w.close()
		var p: DawKitProject = DawKitDawproject.open(file, _tmp("tempo_media"))["project"]
		check("a file with a %s tempo change opens" % interpolation, p != null and p.tempo_points.size() == 2)
		if p == null:
			continue
		var beat := 60.0 / 149.0
		var bass := p.tracks[0].clips[0]
		var notes := {}
		for n in range(0, bass.notes.size(), DawKitClip.NOTE_WIDTH):
			notes[[bass.notes[n + 2], snappedf(bass.notes[n], 0.0001)]] = bass.notes[n + 1]
		var first_four := 4.0 * beat
		if interpolation == "linear":
			# 149 -> 74.5 over four beats: k = -18.625 bpm a beat.
			first_four = 60.0 / -18.625 * log(0.5)
		close("%s: the clip runs as long as it plays, 4 beats then 4 at half speed (%.4f)" % [interpolation, bass.length],
				bass.length, first_four + 8.0 * beat, 0.00001)
		var on := first_four + 2.0 * beat
		check("%s: a note on beat 5 is a beat at the new tempo past the change (%.4f)" % [interpolation, on],
				notes.has([65.0, snappedf(on, 0.0001)]))
		check("%s: the last note, beats 6 to 8, lasts four of the old beats" % interpolation,
				notes.has([53.0, snappedf(first_four + 4.0 * beat, 0.0001)])
				and absf(notes[[53.0, snappedf(first_four + 4.0 * beat, 0.0001)]] - (first_four + 8.0 * beat)) < 0.00001)


func _test_a_tempo_map_survives_the_file() -> void:
	var p := sample()
	p.tempo_points = [[0.0, p.tempo, DawKitTempoMap.HOLD], [8.0, p.tempo * 0.75, DawKitTempoMap.RAMP_SECONDS],
			[16.0, p.tempo * 1.5, DawKitTempoMap.RAMP_BEATS], [24.0, p.tempo, DawKitTempoMap.HOLD]]
	check("a project with a tempo map is sound (%s)" % [p.problems()], p.problems().is_empty())
	var file := _tmp("tempo_map.dawproject")
	DawKitDawproject.save(p, file, _media_root())
	var back: DawKitProject = DawKitDawproject.open(file, _tmp("tempo_map_media"))["project"]
	check("saved and opened, it is the same project (%s)" % (p.first_difference(back) if back else "none"),
			back != null and p.same_as(back))
	_without_extras(file, _tmp("tempo_plain.dawproject"))
	var plain: DawKitProject = DawKitDawproject.open(_tmp("tempo_plain.dawproject"), _tmp("tempo_plain_media"))["project"]
	check("the map is in the XML itself, for any DAW, every ramp a ramp (%s)" % [plain.tempo_points if plain else null],
			plain != null and plain.tempo_points.map(func(pt): return [pt[0], pt[1], pt[2] != 0])
				== p.tempo_points.map(func(pt): return [pt[0], pt[1], pt[2] != 0]))
	if OS.execute("sh", ["-c", "command -v xmllint"]) == 0:
		var zip := ZIPReader.new()
		zip.open(file)
		var xml_path := _tmp("tempo_project.xml")
		FileAccess.open(xml_path, FileAccess.WRITE).store_buffer(zip.read_file("project.xml"))
		zip.close()
		var said: Array = []
		var rc := OS.execute("xmllint", ["--noout", "--schema",
				ProjectSettings.globalize_path("res://tests/fixtures/dawproject/Project.xsd"), xml_path], said, true)
		check("and valid against the official schema (%s)" % str(said).substr(0, 300), rc == 0)
	p.tempo_points = [[0.0, 90.0, false]]
	check("a map that does not start at the tempo is a problem", not p.problems().is_empty())


func _test_the_click_follows_the_tempo_map() -> void:
	var m := DawKitTempoMap.new(120.0)
	m.set_point(4.0, 60.0)
	var clicks := DawKitMetronome.span_clicks(m, 4, 1.25, 4.0)
	var times := clicks.map(func(c): return snappedf(c[0], 0.0001))
	# Beats 3, 4 at 120 (1.5 s, 2.0 s), then 5, 6, 7 at 60 (3.0, 4.0, 5.0 s), from 1.25 s.
	check("clicks fall on the beats through the change (%s)" % [times], times == [0.25, 0.75, 1.75, 2.75, 3.75])
	check("and the bar's first is accented", clicks.map(func(c): return c[1]) == [false, true, false, false, false])
	var rate := 48000
	var wav := DawKitMetronome.span(m, 4, 1.25, 4.0, rate)
	var first := -1
	for f in wav.data.size() / 4:
		if wav.data.decode_s16(f * 4) != 0:
			first = f
			break
	check("rendered, the first click starts on its sample (%d)" % first, first == int(round(0.25 * rate)))
	var accent := int(round(0.75 * rate))
	check("and the accent is the louder one", absi(wav.data.decode_s16(accent * 4)) > absi(wav.data.decode_s16(first * 4)))


func _test_the_meter_counts_bars() -> void:
	var m := DawKitMeter.new(4, 4)
	check("one signature counts bars of four", m.bar_at(8.0) == 2.0 and m.position(9.5) == [3, 2, 0.5])
	# 4/4 for two bars, 6/8 (three beats) from beat 8, 7/8 from beat 13 -- a bar and two
	# thirds of 6/8 later, so the 6/8 bar it falls in is cut short.
	m.set_point(8.0, 6, 8)
	m.set_point(13.0, 7, 8)
	check("a change starts bar 3 (%.3f)" % m.bar_at(8.0), m.bar_at(8.0) == 2.0)
	check("6/8 bars are three beats (%.3f)" % m.bar_at(11.0), m.bar_at(11.0) == 3.0)
	check("a change inside a bar cuts it short and starts the next (%.3f)" % m.bar_at(13.0), m.bar_at(13.0) == 4.0)
	check("and bars go back to beats the same way (%s)" % [[m.beat_of_bar(2.0), m.beat_of_bar(3.0), m.beat_of_bar(4.0), m.beat_of_bar(5.0)]],
			m.beat_of_bar(2.0) == 8.0 and m.beat_of_bar(3.0) == 11.0 and m.beat_of_bar(4.0) == 13.0 and m.beat_of_bar(5.0) == 16.5)
	check("its signature there (%s)" % m.signature_at(13.5), m.signature_at(13.5) == Vector2i(7, 8) and m.signature_at(12.9) == Vector2i(6, 8))
	check("counted in eighths in x/8 (%s)" % [m.position(9.5)], m.position(9.5) == [3, 4, 0.0])
	check("before the song, bars of the first signature", m.bar_at(-4.0) == -1.0 and m.beat_of_bar(-1.0) == -4.0)
	var counts := m.counts(7.0, 14.0)
	check("a click on each count, the bar's first accented (%s)" % [counts], counts == [[7.0, false],
			[8.0, true], [8.5, false], [9.0, false], [9.5, false], [10.0, false], [10.5, false],
			[11.0, true], [11.5, false], [12.0, false], [12.5, false],
			[13.0, true], [13.5, false]])
	var back := DawKitMeter.from_array(m.to_array())
	check("and its points are its own again", back.to_array() == m.to_array() and back.bar_at(13.0) == 4.0)
	var map := DawKitTempoMap.new(120.0)
	var clicks := DawKitMetronome.span_clicks(map, m, 4.0, 2.0)
	check("the click counts the meter (%s)" % [clicks], clicks.map(func(c): return c[0]) == [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75]
			and clicks.map(func(c): return c[1]) == [true, false, false, false, false, false, true, false])


func _test_time_signature_changes_survive_the_file() -> void:
	var p := sample()
	p.time_signature_points = [[0.0, 6, 8], [6.0, 4, 4], [14.0, 7, 8]]
	check("a project with signature changes is sound (%s)" % [p.problems()], p.problems().is_empty())
	var file := _tmp("meter.dawproject")
	DawKitDawproject.save(p, file, _media_root())
	var back: DawKitProject = DawKitDawproject.open(file, _tmp("meter_media"))["project"]
	check("saved and opened, it is the same project (%s)" % (p.first_difference(back) if back else "none"),
			back != null and p.same_as(back))
	_without_extras(file, _tmp("meter_plain.dawproject"))
	var plain: DawKitProject = DawKitDawproject.open(_tmp("meter_plain.dawproject"), _tmp("meter_plain_media"))["project"]
	check("the changes are in the XML itself, for any DAW (%s)" % [plain.time_signature_points if plain else null],
			plain != null and plain.time_signature_points == p.time_signature_points)
	if OS.execute("sh", ["-c", "command -v xmllint"]) == 0:
		var zip := ZIPReader.new()
		zip.open(file)
		var xml_path := _tmp("meter_project.xml")
		FileAccess.open(xml_path, FileAccess.WRITE).store_buffer(zip.read_file("project.xml"))
		zip.close()
		var said: Array = []
		var rc := OS.execute("xmllint", ["--noout", "--schema",
				ProjectSettings.globalize_path("res://tests/fixtures/dawproject/Project.xsd"), xml_path], said, true)
		check("and valid against the official schema (%s)" % str(said).substr(0, 300), rc == 0)
	p.time_signature_points = [[0.0, 3, 4]]
	check("changes that do not start at the signature are a problem", not p.problems().is_empty())


func _test_automation_is_read_along_the_song() -> void:
	var a := DawKitAutomation.new("volume", [[2.0, -12.0, 1], [4.0, 0.0, 0], [6.0, -6.0, 1]])
	close("before the first point, the first value holds", a.value_at(0.0), -12.0)
	close("a straight line between linear points", a.value_at(3.0), -6.0)
	close("a hold stays until the next point", a.value_at(5.99), 0.0)
	close("after the last, the last holds", a.value_at(60.0), -6.0)
	check("with no points, the control's own value", DawKitAutomation.new("pan").value_at(1.0, 0.3) == 0.3)
	check("a target names a control, or nothing", DawKitAutomation.kind_of("fx:1:4") == "fx"
			and DawKitAutomation.kind_of("send:t3") == "send" and DawKitAutomation.kind_of("fx:x") == "")
	var p := sample()
	p.track("t2").automation.append(DawKitAutomation.new("fx:9:0", [[0.0, 0.5, 0]]))
	check("automating an effect that is not there is a problem", not p.problems().is_empty())


func _test_automation_survives_the_file_without_our_extras() -> void:
	var p := sample()
	var file := _tmp("auto.dawproject")
	DawKitDawproject.save(p, file, _media_root())
	_without_extras(file, _tmp("auto_plain.dawproject"))
	var back: DawKitProject = DawKitDawproject.open(_tmp("auto_plain.dawproject"), _tmp("auto_media"))["project"]
	check("a file another DAW re-saved opens with its automation", back != null)
	if back == null:
		return
	for t in p.tracks + [p.master]:
		var other: DawKitTrack = back.track(t.id)
		for a in t.automation:
			var b := other.automation_of(a.target) if other != null else null
			var same: bool = b != null and b.points.size() == a.points.size()
			if same:
				for i in a.points.size():
					same = same and absf(b.points[i][0] - a.points[i][0]) < 0.0001 \
							and absf(b.points[i][1] - a.points[i][1]) < 0.001 and int(b.points[i][2]) == int(a.points[i][2])
			check("%s's %s is in the XML itself (%s)" % [t.name, a.target, b.points if b else null], same)


## The official DAWproject examples (tests/fixtures/dawproject/reference): what each should open
## as -- per clip [track, start s, length s, source offset s, fade s, notes] -- and the warning it
## should give for what dawkit cannot carry, "" for none.
const EXAMPLES := {
	"AudioFILE_WITH_ABSOLUTE_PATH": [[[0, 0.0, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioFILE_WITH_RELATIVE_PATH": [[[0, 0.0, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioRAW_BEATS": [[[0, 0.0, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioRAW_BEATSClipstart": [[[0, 0.3871, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioRAW_BEATSOffset": [[[0, 0.0, 3.0968, 1.0, 0.0, 0]], ""],
	"AudioRAW_BEATSWithFades": [[[0, 0.0, 3.0968, 0.0, 0.1, 0]], ""],
	"AudioRAW_SECONDS": [[[0, 0.0, 3.097, 0.0, 0.0, 0]], ""],
	"AudioRAW_SECONDSClipstart": [[[0, 1.0, 3.097, 0.0, 0.0, 0]], ""],
	"AudioRAW_SECONDSOffset": [[[0, 0.0, 3.097, 1.0, 0.0, 0]], ""],
	"AudioRAW_SECONDSWithFades": [[[0, 0.0, 3.097, 0.0, 0.1, 0]], ""],
	"AudioWARPED": [[[0, 0.0, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioWARPEDClipstart": [[[0, 0.3871, 3.0968, 0.0, 0.0, 0]], ""],
	"AudioWARPEDOffset": [[[0, 0.0, 3.0968, 0.3871, 0.0, 0]], ""],
	"AudioWARPEDWithFades": [[[0, 0.0, 3.0968, 0.0, 0.0968, 0]], ""],
	"MIDI-CC1-AutomationInClips": [[[0, 0.0, 3.9024, 0.0, 0.0, 0]], "automation in the clip"],
	"MIDI-CC1-AutomationOnTrack": [[], "no lane for MIDI expression"],
	"MIDI-PitchBend-AutomationInClips": [[[0, 0.0, 3.9024, 0.0, 0.0, 0]], "automation in the clip"],
	"MIDI-PitchBend-AutomationOnTrack": [[], "no lane for MIDI expression"],
	"test": [[[0, 0.0, 2.0, 0.0, 0.0, 8], [1, 4.0, 2.0, 0.0, 0.0, 8], [2, 8.0, 2.0, 0.0, 0.0, 8]], ""],
	"test-complex": [[[0, 0.0, 2.0, 0.0, 0.0, 8], [0, 16.0, 2.0, 0.0, 0.0, 8], [1, 4.0, 2.0, 0.0, 0.0, 8],
			[1, 20.0, 2.0, 0.0, 0.0, 8], [2, 8.0, 2.0, 0.0, 0.0, 8], [2, 24.0, 2.0, 0.0, 0.0, 8]],
			"state of Limiter is not in the file"],
}


## Each example zipped as the .dawproject the reference implementation wrote: its project.xml,
## and the sound beside it unless the clip points outside the file.
func _example(name: String) -> String:
	var fixtures := ProjectSettings.globalize_path("res://tests/fixtures/dawproject/reference")
	var xml := FileAccess.get_file_as_string(fixtures.path_join(name + ".xml")).replace("@FIXTURES@", fixtures)
	var dir := _tmp("examples").path_join("target")
	DirAccess.make_dir_recursive_absolute(dir)
	# FILE_WITH_RELATIVE_PATH's sound is at ../test-data/, as in the reference repository.
	var data := _tmp("examples").path_join("test-data")
	DirAccess.make_dir_recursive_absolute(data)
	DirAccess.copy_absolute(fixtures.path_join("white-glasses.wav"), data.path_join("white-glasses.wav"))
	var file := dir.path_join(name + ".dawproject")
	var w := ZIPPacker.new()
	w.open(file)
	w.start_file("project.xml")
	w.write_file(xml.to_utf8_buffer())
	w.close_file()
	if not 'external="true"' in xml and 'path="white-glasses.wav"' in xml:
		w.start_file("white-glasses.wav")
		w.write_file(FileAccess.get_file_as_bytes(fixtures.path_join("white-glasses.wav")))
		w.close_file()
	w.close()
	return file


func _valid(file: String) -> String:
	var zip := ZIPReader.new()
	zip.open(file)
	var out := file.get_basename() + "_xml"
	DirAccess.make_dir_recursive_absolute(out)
	FileAccess.open(out.path_join("project.xml"), FileAccess.WRITE).store_buffer(zip.read_file("project.xml"))
	zip.close()
	var said: Array = []
	var rc := OS.execute("xmllint", ["--noout", "--schema",
			ProjectSettings.globalize_path("res://tests/fixtures/dawproject/Project.xsd"),
			out.path_join("project.xml")], said, true)
	return "" if rc == 0 else str(said).substr(0, 300)


func _test_the_official_examples_open_and_come_back() -> void:
	var lint := OS.execute("sh", ["-c", "command -v xmllint"]) == 0
	if not lint:
		print("SKIP  xmllint is not installed: the examples' re-saves are not checked against the schema")
	for name in EXAMPLES:
		var want: Array = EXAMPLES[name]
		var media := _tmp("examples").path_join(name + "_media")
		var opened := DawKitDawproject.open(_example(name), media)
		var p: DawKitProject = opened["project"]
		check("%s opens (%s)" % [name, opened["error"]], p != null)
		if p == null:
			continue
		var warnings: PackedStringArray = opened["warnings"]
		var expected: String = want[1]
		check("%s says what it left out, and only that (%s)" % [name, warnings],
				warnings.size() == (0 if expected == "" else 1)
				and (expected == "" or expected in warnings[0]))
		var got: Array = []
		for i in p.tracks.size():
			for c in p.tracks[i].clips:
				got.append([i, c.start, c.length, c.source_offset, c.fade_in, c.note_count()])
		var clips: Array = want[0]
		var same := got.size() == clips.size()
		for i in mini(got.size(), clips.size()):
			for k in 6:
				same = same and absf(float(got[i][k]) - float(clips[i][k])) < 0.0001
			same = same and is_equal_approx(p.tracks[got[i][0]].clips.filter(
					func(c): return is_equal_approx(c.start, got[i][1]))[0].fade_out, got[i][4])
		check("%s has its clips where they sound (%s)" % [name, got], same)
		for t in p.tracks:
			for c in t.clips:
				if c.source != "":
					var heard := c.source if c.source.is_absolute_path() else media.path_join(c.source)
					check("%s's sound is found (%s)" % [name, c.source], FileAccess.file_exists(heard))
		var again := _tmp("examples").path_join(name + "_again.dawproject")
		DawKitDawproject.save(p, again, media)
		if lint:
			var said := _valid(again)
			check("%s saved again is valid DAWproject (%s)" % [name, said], said == "")
		var back: DawKitProject = DawKitDawproject.open(again, media + "_again")["project"]
		check("%s saved and opened is the same project (%s)" % [name,
				p.first_difference(back) if back else "did not open"], back != null and p.same_as(back))
		var bare := _tmp("examples").path_join(name + "_bare.dawproject")
		_without_extras(again, bare)
		var plain: DawKitProject = DawKitDawproject.open(bare, media + "_bare")["project"]
		check("%s comes back the same without our extras too (%s)" % [name,
				p.first_difference(plain) if plain else "did not open"], plain != null and p.same_as(plain))
	var p: DawKitProject = DawKitDawproject.open(_example("test-complex"), _tmp("examples").path_join("complex"))["project"]
	check("test-complex keeps its master Limiter, its volume lane and its markers",
			p.master.effects.size() == 1 and p.master.effects[0].name == "Limiter"
			and p.tracks[0].automation.size() == 1 and p.tracks[0].automation[0].target == "volume"
			and p.markers.size() == 2 and p.markers[1].name == "Chorus")


# --- hosted plugins ------------------------------------------------------------------------------

## The CLAP built beside the extension for these checks (native/test_plugin), or "" where plugins
## are not hosted.
func _test_plugin() -> String:
	if not ClassDB.class_exists(&"DawKitPlugin") or not ClassDB.class_call_static(&"DawKitPlugin", &"hosting_available"):
		return ""
	var path := ProjectSettings.globalize_path("res://native/build/dawkit_test.clap")
	return path if FileAccess.file_exists(path) else ""


func _loaded(id: String) -> Object:
	var p = ClassDB.instantiate(&"DawKitPlugin")
	if not p.load({"format": "CLAP", "id": id, "path": _test_plugin()}):
		check("the test plugin %s loads (%s)" % [id, p.get_error()], false)
		return null
	p.activate(48000.0, 512)
	return p


func _test_plugins_are_found_and_described() -> void:
	var path := _test_plugin()
	if path == "":
		check("the test plugin is built (tools/build_native.sh)", not ClassDB.class_exists(&"DawKitPlugin"))
		return
	var found: Array = ClassDB.class_call_static(&"DawKitPlugin", &"scan_file", "CLAP", path)
	var ids := found.map(func(d: Dictionary) -> String: return d["id"])
	check("a scan finds both plugins in the file (%s)" % [ids], ids == ["dawkit.test.gain", "dawkit.test.sine"])
	check("and knows the instrument from the effect", found.size() == 2
			and not found[0]["instrument"] and found[1]["instrument"])
	check("and says where each is", found.size() == 2 and found[0]["path"] == path and found[0]["name"] == "Test Gain")
	var dir := path.get_base_dir()
	var files: PackedStringArray = ClassDB.class_call_static(&"DawKitPlugin", &"find_files", "CLAP", PackedStringArray([dir]))
	check("the file is found by looking in its folder", path in files)
	# The scanner, in a process of its own, says the same.
	var scanner := ProjectSettings.globalize_path("res://addons/dawkit/bin/dawkit_scan.linux.x86_64")
	var out := []
	var rc := OS.execute(scanner, ["CLAP", path], out)
	var parsed = JSON.parse_string(out[0] if out.size() > 0 else "")
	check("dawkit_scan finds the same, as JSON (rc %d)" % rc, rc == 0 and parsed is Array and parsed.size() == 2
			and parsed[1]["id"] == "dawkit.test.sine" and parsed[1]["instrument"] == true)
	var bad = ClassDB.instantiate(&"DawKitPlugin")
	check("a plugin that is not there will not load, and says so",
			not bad.load({"format": "CLAP", "id": "no.such", "path": path}) and bad.get_error() != "")


func _test_a_plugin_effect_changes_the_sound() -> void:
	if _test_plugin() == "":
		return
	var p = _loaded("dawkit.test.gain")
	if p == null:
		return
	check("the effect has its one parameter", p.param_count() == 1 and p.param_info(0)["name"] == "Gain")
	close("its value starts at its default (1 of 0-2, normalised)", p.get_param(0), 0.5)
	var dc := PackedVector2Array()
	dc.resize(2000)
	dc.fill(Vector2(0.8, -0.4))
	var out: PackedVector2Array = p.process(dc)
	close("at its default the sound comes through as it went in", out[1999].x, 0.8, 0.001)
	p.set_param(0, 0.25)
	out = p.process(dc)
	close("set to half, it is half as loud, from the next block", out[1999].x, 0.4, 0.001)
	close("on both channels", out[1999].y, -0.2, 0.001)
	check("and the plugin says so in its own words (%s)" % p.param_text(0), p.param_text(0) == "-6.0 dB")
	check("a stereo effect is two channels in and out", p.input_channels() == 2 and p.output_channels() == 2)


func _test_a_plugins_state_comes_back() -> void:
	if _test_plugin() == "":
		return
	var a = _loaded("dawkit.test.gain")
	if a == null:
		return
	a.set_param(0, 0.75)
	var dc := PackedVector2Array()
	dc.resize(600)
	dc.fill(Vector2(0.5, 0.5))
	a.process(dc)  # the plugin takes the value in its next block
	var state: PackedByteArray = a.get_state()
	check("a plugin's state is saved (%d bytes)" % state.size(), state.size() > 0)
	var b = _loaded("dawkit.test.gain")
	check("and loads into another of it", b.set_state(state))
	close("which then has the value it was saved with", b.get_param(0), 0.75, 0.0001)
	close("and sounds it", b.process(dc)[599].x, 0.75, 0.001)


func _test_an_instrument_plugin_plays_live_notes() -> void:
	if _test_plugin() == "":
		return
	var p = _loaded("dawkit.test.sine")
	if p == null:
		return
	check("an instrument is one", p.is_instrument() and p.input_channels() == 0 and p.output_channels() == 2)
	var silence := PackedVector2Array()
	silence.resize(4800)
	var loudest := func(frames: PackedVector2Array) -> float:
		var m := 0.0
		for f in frames:
			m = maxf(m, absf(f.x))
		return m
	close("it is silent before a note", loudest.call(p.process(silence)), 0.0)
	p.note_on(69, 127)
	var heard: float = loudest.call(p.process(silence))
	close("a note played on it sounds, at its level (%.3f)" % heard, heard, 0.5, 0.01)
	p.note_off(69)
	p.process(silence)
	close("and stops when it is let go", loudest.call(p.process(silence)), 0.0)


func _test_a_lane_plays_its_notes_through_its_instrument() -> void:
	if _test_plugin() == "":
		return
	var p = _loaded("dawkit.test.sine")
	if p == null:
		return
	var t = ClassDB.instantiate(&"DawKitTransport")
	t.set_rate(48000)
	var lane = ClassDB.instantiate(&"DawKitLane")
	lane.set_transport(t)
	lane.set_instrument(p)
	# One note from 0.5 s to 0.6 s.
	lane.set_notes(PackedFloat64Array([0.5, 0.6, 69, 127, 0]))
	check("the lane has its note", lane.note_count() == 1)
	var a = lane.instantiate_playback()
	var b = lane.instantiate_playback()
	var out_a := PackedVector2Array()
	var out_b := PackedVector2Array()
	for k in 2:
		a.mix_audio(1.0, 512)
		b.mix_audio(1.0, 512)
	t.play_from(0.4, 0.01)
	var started: int = t.get_anchor_clock()
	for k in 30:
		out_a.append_array(a.mix_audio(1.0, 512))
		out_b.append_array(b.mix_audio(1.0, 512))
	var first := -1
	var last := -1
	for i in out_a.size():
		if absf(out_a[i].x) > 0.0001:
			if first < 0:
				first = i
			last = i
	var base := 2 * 512
	var expected := started + int(0.1 * 48000) - base
	# A sine starts at 0, so its first sound is the sample after the note.
	check("the note starts on its sample (%d, wanted %d)" % [first, expected], absi(first - expected) <= 1)
	check("and ends on its own (%d, wanted under %d)" % [last, expected + 4800], last > expected + 4700 and last < expected + 4800)
	check("two playbacks of the lane hear the same instrument, played once", out_a == out_b)
	# A note played on the plugin live is heard through the lane, stopped or not.
	t.stop()
	p.note_on(60, 100)
	var live := PackedVector2Array()
	for k in 4:
		live.append_array(a.mix_audio(1.0, 512))
	var any := false
	for f in live:
		any = any or absf(f.x) > 0.01
	check("a note played live sounds through the lane while the song is stopped", any)
	p.all_notes_off()


func _test_a_plugin_effect_runs_once_for_every_bus_it_is_on() -> void:
	if _test_plugin() == "":
		return
	var p = _loaded("dawkit.test.gain")
	if p == null:
		return
	var e = ClassDB.instantiate(&"DawKitPluginEffect")
	e.set_plugin(p)
	check("a plugin effect holds its plugin", e.get_plugin() == p)
	p.set_param(0, 0.25)
	# Two buses (a track's and its send's) with the effect, each block after a lane has moved the
	# song's clock, as the server mixes them: streams first, then each bus's effects.
	var t = ClassDB.instantiate(&"DawKitTransport")
	t.set_rate(48000)
	e.set_transport(t)
	var lane = ClassDB.instantiate(&"DawKitLane")
	lane.set_transport(t)
	var clock = lane.instantiate_playback()
	var block := PackedVector2Array()
	block.resize(512)
	var before: int = p.blocks_run()
	var same := true
	var level := 0.0
	for k in 8:
		clock.mix_audio(1.0, 512)
		for i in 512:
			block[i] = Vector2(0.5, 0.5) * (1.0 if (k + i) % 2 == 0 else -1.0)
		var order := [0, 1] if k % 2 == 0 else [1, 0]
		var a: PackedVector2Array = e.process_as(order[0], block)
		var b: PackedVector2Array = e.process_as(order[1], block)
		same = same and a == b
		level = a[511].x
	check("the plugin runs once a block for both buses (%d runs in 8 blocks)" % (p.blocks_run() - before),
			p.blocks_run() - before == 8)
	check("and both hear what it made", same)
	close("which is the effect's sound", absf(level), 0.25, 0.001)
	e.set_bypass(true)
	close("bypassed, the sound goes through untouched", e.process_as(0, block)[0].x, block[0].x)


func _test_a_frozen_track_can_be_thawed_and_is_saved() -> void:
	var p := sample()
	var kick: DawKitTrack = p.tracks[0]
	for t in p.tracks:
		if t.comp.size() > 0:
			kick = t
	var before := kick.to_dict()
	var fx_before := kick.effects.size()
	var bounce := DawKitClip.new()
	bounce.start = 0.0
	bounce.length = 40.0
	bounce.source = "audio/take1.wav"
	check("an unfrozen track is not frozen", not kick.is_frozen() and not kick.unfreeze())
	check("it freezes", kick.freeze(bounce) and kick.is_frozen())
	check("its clips are the one rendered clip, with no comp and no effects",
			kick.clips.size() == 1 and kick.comp.is_empty() and kick.effects.is_empty())
	check("a frozen track will not freeze again", not kick.freeze(bounce))
	var plain := DawKitTrack.from_dict(kick.to_dict())
	check("frozen survives the plain form", plain.is_frozen() and plain.to_dict() == kick.to_dict())
	var file := _tmp("frozen.dawproject")
	var warnings := DawKitDawproject.save(p, file, _media_root())
	check("a project with a frozen track saves (%s)" % [warnings], warnings.is_empty())
	var opened := DawKitDawproject.open(file, _tmp("frozen_opened"))
	check("and opens (%s)" % opened["error"], opened["project"] != null)
	if opened["project"] != null:
		check("the same, frozen (%s)" % p.first_difference(opened["project"]), p.same_as(opened["project"]))
	check("thawed, the track is as it was", kick.unfreeze() and not kick.is_frozen()
			and kick.to_dict() == before and kick.effects.size() == fx_before)


func _test_a_clip_keeps_controller_and_pitch_bend_lanes() -> void:
	var c := DawKitClip.new()
	c.start = 10.0
	c.length = 4.0
	c.set_control_lane(1, [[1.0, 20], [0.0, 0], [2.0, 120]])
	c.set_control_lane(DawKitClip.PITCH_BEND, [[0.5, -2000.0], [1.5, 99999.0]], 3)
	check("a lane is in time order (%s)" % [c.control_lane(1)], c.control_lane(1) == [[0.0, 0.0], [1.0, 20.0], [2.0, 120.0]])
	check("a bend is clamped to 14 bits, on its channel", c.control_lane(DawKitClip.PITCH_BEND, 3) == [[0.5, -2000.0], [1.5, 8191.0]]
			and c.control_lane(DawKitClip.PITCH_BEND).is_empty())
	check("a value is the last event at or before it", c.control_at(1, 1.5) == 20.0 and c.control_at(1, 2.0) == 120.0
			and c.control_at(7, 1.0, 0, 64.0) == 64.0)
	c.set_control_lane(1, [])
	check("an empty lane takes it away and leaves the others", c.control_lane(1).is_empty() and c.control_count() == 2)
	check("a bad event is dropped", DawKitClip.clean_controls([1.0, 300, 5, 0, -1.0, 1, 5, 0, INF, 1, 5, 0, 2.0, 1, 500, 99]) == PackedFloat64Array([2.0, 1.0, 127.0, 15.0]))
	var back := DawKitClip.from_dict(c.to_dict())
	check("they survive the plain form", back.controls == c.controls)
	c.set_control_lane(1, [[0.5, 10], [3.0, 30]])
	var cut := c.slice(11.0, 13.0)
	check("a slice leaves out what lies outside its window", cut.control_count() == 1 and cut.control_lane(DawKitClip.PITCH_BEND, 3) == [[0.5, 8191.0]])
	var cut2 := c.slice(10.25, 13.5)
	check("and moves the rest by what was cut off (%s)" % [cut2.control_lane(1)],
			cut2.control_lane(1) == [[0.25, 10.0], [2.75, 30.0]] and cut2.control_lane(DawKitClip.PITCH_BEND, 3) == [[0.25, -2000.0], [1.25, 8191.0]])


func _test_a_comp_picks_which_take_sounds() -> void:
	var t := DawKitTrack.new("t", "Vox")
	var a := DawKitClip.new()
	a.start = 0.0
	a.length = 8.0
	a.source = "a.wav"
	a.fade_in = 0.5
	a.fade_out = 0.5
	var b := DawKitClip.new()
	b.start = 0.0
	b.length = 8.0
	b.source = "b.wav"
	b.lane = 1
	t.clips = [a, b]
	check("two lanes", t.lane_count() == 2)
	check("with no comp both sound", t.playing_clips().size() == 2)
	t.set_comp(2.0, 5.0, 1)
	check("a comp from nothing keeps the rest on the first lane (%s)" % [t.comp],
			t.comp == [[0.0, 2.0, 0], [2.0, 5.0, 1], [5.0, 8.0, 0]])
	var pl := t.playing_clips()
	check("so the first take plays either side of the second", pl.size() == 3
			and pl[0].source == "a.wav" and pl[1].source == "b.wav" and pl[2].source == "a.wav")
	check("each piece is where its stretch is", pl[0].start == 0.0 and pl[0].length == 2.0
			and pl[1].start == 2.0 and pl[1].length == 3.0 and pl[2].start == 5.0 and pl[2].length == 3.0)
	check("and starts that far into its file", pl[1].source_offset == 2.0 and pl[2].source_offset == 5.0)
	check("a fade stays only on an end that is still the clip's", pl[0].fade_in == 0.5 and pl[0].fade_out == 0.0
			and pl[2].fade_in == 0.0 and pl[2].fade_out == 0.5)
	t.set_comp(5.0, 8.0, 1)
	check("choosing the same lane next door joins the stretches", t.comp == [[0.0, 2.0, 0], [2.0, 8.0, 1]])
	t.set_comp(3.0, 4.0, 0)
	check("a stretch inside another splits it", t.comp == [[0.0, 2.0, 0], [2.0, 3.0, 1], [3.0, 4.0, 0], [4.0, 8.0, 1]])
	var m := DawKitClip.new()
	m.start = 10.0
	m.length = 4.0
	m.notes = PackedFloat64Array([0.5, 1.5, 60, 100, 0, 2.5, 3.5, 64, 90, 0])
	var cut := m.slice(11.0, 14.0)
	check("a sliced MIDI clip keeps the notes in its window, counted from its start (%s)" % [cut.notes],
			cut.notes == PackedFloat64Array([0.0, 0.5, 60, 100, 0, 1.5, 2.5, 64, 90, 0]))
	var flat := DawKitTrack.from_dict(t.to_dict())
	flat.flatten_comp()
	check("flattened, the comp is gone and every clip is on the first lane, as many as sounded",
			flat.comp.is_empty() and flat.clips.size() == 4 and flat.clips.all(func(c): return c.lane == 0))
	var back := DawKitTrack.from_dict(t.to_dict())
	check("lanes and the comp survive the plain form", back.comp == t.comp and back.clips[1].lane == 1)
