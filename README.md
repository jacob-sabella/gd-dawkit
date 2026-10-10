# dawkit

A DAW engine that runs inside Godot: a project model (tracks, folders, sends, effects, clips,
markers, tempo), a mixer and transport on Godot's own `AudioServer`, and project files in
**DAWproject**, the open interchange format that Bitwig, Studio One and Cubase read and write.

It has no user interface of its own. A host application (a game, a 3D studio, an app) draws
whatever it likes and drives the engine through its API. dawlings (a 3D studio game) is the first host.

## Layout

    addons/dawkit/          the engine: the only directory a host needs
      project/              the project model (DawKitProject and its parts)
    tests/                  the engine's own checks, run headless
    tools/test.sh           runs them

## Rules the engine keeps

- **Nothing from a host.** No class, autoload or path from any application that uses it. A host
  adapts to the engine, never the reverse.
- **Plain data at the edge.** Every part of a project has `to_dict()`/`from_dict()`, and a
  project captured, saved, loaded and captured again comes back identical.
- **Every class is prefixed `DawKit`**, because Godot's class names are global and an addon
  shares them with its host.

## Licence

Proprietary. See LICENSE.
