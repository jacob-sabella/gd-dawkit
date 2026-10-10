extends SceneTree

## dawkit's own checks. Headless, no host application: `tools/test.sh`.

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_a_project_survives_its_plain_form()
	_test_every_field_is_in_the_plain_form()
	_test_a_difference_is_found_and_named()
	_test_folders_route_to_their_parent()
	_test_broken_references_are_reported()
	_test_a_project_survives_a_dawproject_file()
	_test_the_file_is_valid_dawproject()
	_test_a_file_without_our_extras_still_opens()
	_test_a_bitwig_file_opens()
	_test_odd_names_survive_the_xml()
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
