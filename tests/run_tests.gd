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
