# dawkit

A DAW engine that runs inside Godot: a project model (tracks, folders, sends, effects, clips,
markers, tempo), a mixer and transport on Godot's own `AudioServer`, and project files in
**DAWproject**, the open interchange format that Bitwig, Studio One and Cubase read and write.

It has no user interface of its own. A host application (a game, a 3D studio, an app) draws
whatever it likes and drives the engine through its API. dawlings (a 3D studio game) is the first host.

## Layout

    addons/dawkit/          the engine: the only directory a host needs
      project/              the project model (DawKitProject and its parts)
      io/                   DAWproject files (DawKitDawproject) and the XML they are made of
    tests/                  the engine's own checks, run headless
    tools/test.sh           runs them

## Rules the engine keeps

- **Nothing from a host.** No class, autoload or path from any application that uses it. A host
  adapts to the engine, never the reverse.
- **Plain data at the edge.** Every part of a project has `to_dict()`/`from_dict()`, and a
  project captured, saved, loaded and captured again comes back identical.
- **Every class is prefixed `DawKit`**, because Godot's class names are global and an addon
  shares them with its host.

## DAWproject

`DawKitDawproject.save(project, path, media_root)` writes a `.dawproject`, and
`DawKitDawproject.open(path, media_dir)` reads one, from dawkit or from another DAW. Output is
checked against the official schema in the tests (`tests/fixtures/dawproject`, MIT, from
github.com/bitwig/dawproject).

What another DAW reads from a dawkit file: tempo, time signature, tracks and folders, levels, pans,
mutes, solos, sends, effects (dawkit's own as generic built-in devices with their parameters,
third-party plug-ins with their saved state), clips with fades and file offsets, MIDI notes, and
markers. What only dawkit reads back, from `dawkit/extras.json` in the same zip: the loop, the
metronome, the project's length, clip gain, record arm, monitor mode, effect wet/dry and preset
names, and sidechain keys (which DAWproject cannot express, so they are left out of the XML rather
than written as ordinary sends).

## Licence

Proprietary. See LICENSE.
