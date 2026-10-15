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
    native/                 the native core (GDExtension): lanes, transport, plugin hosting
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
extensible), AIFF and AIFF-C, FLAC, Ogg Vorbis and MP3 into samples, folding more than two channels to
stereo. `bring_in(source, dest)` puts a file in a project's media: copied untouched when the engine
plays it as it is, otherwise written as a 32-bit float WAV, with its length and a 50-per-second
overview. Ogg and MP3 are decoded by Godot at the audio server's mix rate. FLAC is decoded by
`DawKitFlac`, written from RFC 9639: every subframe and residual kind, 4 to 32 bits, any channel
count, checked against the file's own MD5. In GDScript it takes about 9 s for a 3-minute 24-bit
stereo file; tests compare 11 files from the reference encoder to the WAVs they came from.

## The native core

`native/` is a GDExtension in C++ (godot-cpp, MIT), built by `tools/build_native.sh` into
`addons/dawkit/bin` (cmake and a C++17 compiler; `tools/test.sh` builds it first). It mixes the
engine's sound sample by sample, which Godot's own players cannot: a player can only start on the
next mix step, so two started together can be a step apart.

`DawKitTransport` is the song's clock, shared by every lane: the lanes count Godot's mix blocks
between them (the first mixed in a block moves the clock on), and the song is anchored to that
clock, so every lane turns a moment into the same song sample. `DawKitLane` is an AudioStream
for one track: its clips (sound, start, length, offset, gain, fades as curves, a looped stretch),
played wherever the transport says the song is, on the track's own bus. The tests mix two lanes
a block at a time in alternating order, and a third that joined late, and find a clip's first
sample on the same frame in all three.

## Metronome

`DawKitMetronome.bar(tempo, beats, rate)` is one bar of clicks as a looping stream, each click
starting at full level on its beat (the first beat higher and louder), so a player started at the
right point in the bar keeps time and a recording of it can be measured against the beat.

## Instrument

`DawKitTine` is a two-operator electric piano, sixteen voices, with a damper and a sustain pedal.
Played live a note at a time, or a whole clip at once with `render_notes(notes, seconds, rate)`,
where each note starts on its own sample. In a project it is an effect of kind `"tine"` with
`instrument` set, written to DAWproject as a `BuiltinDevice` with `deviceRole="instrument"`.

## Third-party plugins

The engine hosts **CLAP and VST3** plugins on Linux and Windows, and **LV2** on Linux, effects and
instruments, with their own windows. `native/src/plugins` is plain C++ over the formats' interface
headers (`native/third_party`: CLAP and VST3 3.8 under MIT, LV2 and lilv under ISC); no SDK
hosting code. lilv (for LV2) and Xlib (for windows) are opened at run time, so a Linux system
without them still loads the engine, with fewer plugins. Android builds with hosting left out
(`DawKitPlugin.hosting_available()` is false; `DawKitPlugin.formats()` lists what a build hosts).

- **Finding them.** `addons/dawkit/bin/dawkit_scan.<system>.<arch>` (`.exe` on Windows) looks at
  one file in a process of its own and prints JSON (`dawkit_scan VST3 <bundle>`, `CLAP <file>`,
  `LV2` for every LV2 plugin, `files <FORMAT>` for the files in the usual places; `--out <file>`
  first to have it written to a file instead), so a plugin that crashes as it starts costs its own
  entry, not the host. An exported game ships it beside its executable. `DawKitPlugin.scan_file` does the same in-process. Plugins under
  yabridge (Windows plugins under Wine) scan and load like native ones.
- **`DawKitPlugin`** is one loaded instance: parameters (normalised 0-1, with the plugin's own
  text for a value, and the ones its window moved), state (a VST3 as a `.vstpreset`, the form a
  DAWproject keeps it in; CLAP's own stream; LV2 state as Turtle), live notes, latency, and its
  window. Call `DawKitPlugin.pump()` once a frame: plugins' timers, the work they ask for on the
  main thread, and their windows run from it.
- **Effects.** A `DawKitPluginEffect` goes on a bus like any AudioEffect. Put on several buses that
  play the same lane (a track's, its sends', its cue's), it runs the plugin once a block, told apart
  by the transport's clock, and the other buses hear what it made.
- **Instruments.** `DawKitLane.set_instrument(plugin)` and `set_notes(notes)` play a lane's notes
  through the plugin, each on its sample, through loops and jumps (whatever was sounding stops), and
  notes played live on the plugin sound through the lane whether the song plays or not.
- **Windows.** A plugin's window is embedded in a window of the engine's, kept off every screen;
  `editor_capture()` reads it into `editor_image()`, and `editor_pointer_*`, `editor_wheel` and
  `editor_key` send input into it, so a host shows the window wherever it likes (a texture in 3D,
  a panel) and nothing appears on the desktop. On Linux that is an X11 window, read with
  XGetImage (a fully headless display, Xvfb, works too). On Windows it is a tool window read with
  PrintWindow, and the mouse is posted to the plugin's window under the point. Because nothing
  is under the real cursor there, the engine:
  - holds back the mouse-leave Windows reports at once;
  - hands back the mouse capture a plugin takes on a click, so the host's own window keeps the
    real mouse;
  - steers `WindowFromPoint` for the whole process (a 12-byte jump at user32's, to the engine's,
    which answers for its own windows and asks `win32u!NtUserWindowFromPoint` for everything else).
  JUCE plugins take no click without that last one.
- **Menus.** On Linux a plugin's dropdowns and right-click menus are windows of their own on the
  desktop. One that maps just after a click into a plugin's window, from the process drawing it,
  and is not a window of its own (an ordinary window or a dialog) is drawn over the plugin's
  picture where it opened, and the pointer and keys go to it; a click outside it closes it.
  Override-redirect menus are moved into a window of the engine's, off every screen. A menu Wine
  draws (yabridge's plugins) is placed by the window manager and closes if it is moved or focused,
  so on Hyprland, while a plugin's window is being clicked, the engine turns on a rule through
  `hyprctl eval` that puts an `.exe`'s untitled window, or one titled "menu", on the special
  workspace `dawkit`, unfocused. The rule switches itself off 4 seconds after the last click. A
  Wine plugin also closes its menus when its window is not the active one, so from a click until
  its menus close the engine names the plugin's window in `_NET_ACTIVE_WINDOW` (a thread of its
  own names it again whenever the window manager changes it).
  Other Wine programs' menus opened in that time go there too. Set `DAWKIT_NO_HYPRLAND_RULE` to
  leave the window manager alone; such menus then appear wherever it puts them.

The tests use a CLAP built for them (`native/test_plugin`: a gain and a sine instrument).

## Tempo map

`DawKitTempoMap` puts beats into seconds and back for a song whose tempo changes: points of
beat, tempo and whether the tempo holds or ramps in a straight line to the next point. Ramps are
integrated exactly. A project keeps its map as `tempo_points` (empty for one tempo); clips and
markers stay in seconds, so the map is for counting bars and for files that count in beats.

## Automation

A track's `automation` is a lane per control (`DawKitAutomation`): its fader in dB, its pan, its
mute, a send's level (`send:<track id>`) or an effect's parameter (`fx:<effect>:<parameter>`),
as points of seconds, value and shape (hold, or a straight line to the next point). In DAWproject
each lane is `Points` in the track's lane, aimed at the parameter by the id its channel gives it,
in that parameter's unit.

## DAWproject

`DawKitDawproject.save(project, path, media_root)` writes a `.dawproject`, and
`DawKitDawproject.open(path, media_dir)` reads one, from dawkit or from another DAW. Output is
checked against the official schema in the tests (`tests/fixtures/dawproject`, MIT, from
github.com/bitwig/dawproject). Times another DAW gives in beats are put into seconds through the
file's tempo map, each measured from where it starts, so a clip across a tempo change is as long
as it sounds.

What another DAW reads from a dawkit file: tempo and its changes (`TempoAutomation`), time signature, tracks and folders, levels, pans,
mutes, solos, sends, effects (dawkit's own as generic built-in devices with their parameters,
third-party plug-ins with their saved state), clips with fades and file offsets, MIDI notes, automation, and
markers. What only dawkit reads back, from `dawkit/extras.json` in the same zip: the loop, the
metronome, the project's length, clip gain, record arm, monitor mode, effect wet/dry and preset
names, and sidechain keys (which DAWproject cannot express, so they are left out of the XML rather
than written as ordinary sends).

## Vibe Coded

This entire project was vibe coded with [Claude Code](https://claude.ai/code). The project model,
the mixer and transport, DAWproject import and export, the native core and the tests — all of it.
No hand-written code.

## Licence

Proprietary. See LICENSE.
