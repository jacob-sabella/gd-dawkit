# dawkit

A DAW engine that runs inside Godot: a project model (tracks, folders, sends, effects, clips,
markers, tempo), a mixer and transport on Godot's own `AudioServer`, and project files in
**DAWproject**, the open interchange format that Bitwig, Studio One and Cubase read and write.

It has no user interface of its own. A host application (a game, a 3D studio, an app) draws
whatever it likes and drives the engine through its API. dawlings (a 3D studio game) is the first host.

## Layout

    addons/dawkit/          the engine: the only directory a host needs
      project/              the project model (DawKitProject and its parts)
      io/                   DAWproject files (DawKitDawproject) and the XML they are made of;
                            audio files people bring (DawKitAudioFile)
      engine/               the click (DawKitMetronome) and the built-in instrument (DawKitTine)
    tests/                  the engine's own checks, run headless
    tools/test.sh           runs them

## Rules the engine keeps

- **Nothing from a host.** No class, autoload or path from any application that uses it. A host
  adapts to the engine, never the reverse.
- **Plain data at the edge.** Every part of a project has `to_dict()`/`from_dict()`, and a
  project captured, saved, loaded and captured again comes back identical.
- **Every class is prefixed `DawKit`**, because Godot's class names are global and an addon
  shares them with its host.

## Audio files

`DawKitAudioFile.read(path)` reads WAV (8/16/24/32-bit integer, 32/64-bit float, plain or
extensible), AIFF and AIFF-C, Ogg Vorbis and MP3 into samples, folding more than two channels to
stereo. `bring_in(source, dest)` puts a file in a project's media: copied untouched when the engine
plays it as it is, otherwise written as a 32-bit float WAV, with its length and a 50-per-second
overview. Ogg and MP3 are decoded by Godot at the audio server's mix rate. FLAC is not read yet.

## Metronome

`DawKitMetronome.bar(tempo, beats, rate)` is one bar of clicks as a looping stream, each click
starting at full level on its beat (the first beat higher and louder), so a player started at the
right point in the bar keeps time and a recording of it can be measured against the beat.

## Instrument

`DawKitTine` is a two-operator electric piano, sixteen voices, with a damper and a sustain pedal.
Played live a note at a time, or a whole clip at once with `render_notes(notes, seconds, rate)`,
where each note starts on its own sample. In a project it is an effect of kind `"tine"` with
`instrument` set, written to DAWproject as a `BuiltinDevice` with `deviceRole="instrument"`.

## Tempo map

`DawKitTempoMap` puts beats into seconds and back for a song whose tempo changes: points of
beat, tempo and whether the tempo holds or ramps in a straight line to the next point. Ramps are
integrated exactly. A project keeps its map as `tempo_points` (empty for one tempo); clips and
markers stay in seconds, so the map is for counting bars and for files that count in beats.

## DAWproject

`DawKitDawproject.save(project, path, media_root)` writes a `.dawproject`, and
`DawKitDawproject.open(path, media_dir)` reads one, from dawkit or from another DAW. Output is
checked against the official schema in the tests (`tests/fixtures/dawproject`, MIT, from
github.com/bitwig/dawproject). Times another DAW gives in beats are put into seconds through the
file's tempo map, each measured from where it starts, so a clip across a tempo change is as long
as it sounds.

What another DAW reads from a dawkit file: tempo and its changes (`TempoAutomation`), time signature, tracks and folders, levels, pans,
mutes, solos, sends, effects (dawkit's own as generic built-in devices with their parameters,
third-party plug-ins with their saved state), clips with fades and file offsets, MIDI notes, and
markers. What only dawkit reads back, from `dawkit/extras.json` in the same zip: the loop, the
metronome, the project's length, clip gain, record arm, monitor mode, effect wet/dry and preset
names, and sidechain keys (which DAWproject cannot express, so they are left out of the XML rather
than written as ordinary sends).

## Licence

Proprietary. See LICENSE.
