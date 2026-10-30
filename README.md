# dawkit

A DAW engine that runs inside Godot: a project model (tracks, folders, sends, effects, clips,
markers, tempo), a mixer and transport on Godot's own `AudioServer`, and project files in
**DAWproject**, the open interchange format that Bitwig, Studio One and Cubase read and write.

It needs Godot 4.7 or later. The engine has no user interface of its own: a host application (a
game, a 3D studio, an app) draws whatever it likes and drives the engine through its API. dawlings
(a 3D studio game) is the first host. For a host that wants an ordinary one, `ui/` is a 2D DAW
interface built only on the engine's own classes (see "2D interface").

## Layout

    addons/dawkit/          the engine: the only directory a host needs
      project/              the project model (DawKitProject and its parts)
      io/                   DAWproject files (DawKitDawproject) and the XML they are made of;
                            audio files people bring (DawKitAudioFile)
      engine/               the click (DawKitMetronome) and the built-in instrument (DawKitTine)
      ui/                   the 2D interface (DawKitStudio) and what it asks of a host (DawKitHost)
    native/                 the native core (GDExtension): lanes, transport, plugin hosting
      third_party/          the plugin formats' interface headers (see THIRD_PARTY_NOTICES.md)
    tests/                  the engine's own checks, run headless
    tools/test.sh           runs them

## Rules the engine keeps

- **Nothing from a host.** No class, autoload or path from any application that uses it. A host
  adapts to the engine, never the reverse.
- **Plain data at the edge.** Every part of a project has `to_dict()`/`from_dict()`, and a
  project captured, saved, loaded and captured again comes back identical.
- **Every class is prefixed `DawKit`**, because Godot's class names are global and an addon
  shares them with its host.

## 2D interface

`DawKitStudio` is a whole DAW window as one Control: a transport bar (play, stop, record, loop,
click, bars and time, tempo, undo and redo), the arrangement (a ruler of bars with markers and the
loop, a lane per track with its header, clips drawn with their waves or notes, the playhead) and
the mixer (a strip per track with its effect chain and sends, fader, level meter, pan, mute,
solo and arm, and the master), an effect panel with the open effect's controls, and a piano roll
for a MIDI clip's notes.

It never edits a project itself. It draws `host.project()` and asks a `DawKitHost` for every
change by track id, in decibels, pan -1..1 and seconds, and shows whatever the host then says,
gathered once a frame. `can()` says which edits a host answers, and the interface leaves out the
rest. `DawKitProjectHost` is a host that is just a project in memory, with undo, and a clock for
a transport (no sound: that is the host's mixer):

    var studio := DawKitStudio.new(DawKitProjectHost.new(project))
    add_child(studio)

An application with its own engine, a network or a session in between implements `DawKitHost`
over that instead. `DawKitLook.use_signals` (mute, solo, record, ok, warn, over) and
`DawKitLook.set_text_scale` restyle it for a reader's eyes, before a studio is made. F1 lists every
key, and the status line says what is under the pointer. FILE on the transport starts, opens (recent ones too), saves and renders, as
the host can (FILES, SAVE, RENDER), and a status line along the bottom says what the host says
(`DawKitHost.said`). Keys while it shows: Ctrl+N, Ctrl+O, Ctrl+S, Ctrl+Shift+S, Space, Ctrl+R, Home, L, C, Ctrl+Z / Ctrl+Shift+Z, and
F5, F6, F7 for the arrangement, the mixer or both. In the arrangement, click the ruler or an empty
lane to seek; click a clip to select it (Shift or Ctrl to add; a box drawn on an empty lane
selects what it touches); drag a clip (to another track too) to move it, on the beat unless Alt
is held; drag its edges to trim it, the handles at its name bar's corners to fade it and the one
in the middle for its gain; right-click it for a menu. S splits the selection at the playhead,
Del deletes it, Ctrl+D duplicates it, Ctrl+A selects everything and Esc nothing. The wheel scrolls
tracks, Shift+wheel the song, Ctrl+wheel zooms, Alt+wheel makes the lanes taller or shorter, the
middle button drags the view. A track's header: double-click its name to rename it, drag it to
move the track (a folder takes what is in it along), right-click it for new, duplicate, colour,
into the folder above, out of its folder and delete, and its - or + to shut or open a folder; the
+ above the headers (or Ctrl+T) adds a track. `DawKitProject.move_track` and `remove_track` keep a
project's folders whole. On a strip: + FX adds an effect (grouped by plugin format), its light
bypasses it, its name opens its controls, a drag moves it along the chain or to another strip,
and right-click has the rest; + SEND sends the track to another, with a level and, on
right-click, before or after the fader.

The ruler has three rows. In the top one, double-click for a marker; drag a marker or a region
(by its middle or either end) to move it; double-click one to rename it. In the middle one are
the tempo's and time signature's changes: double-click one to set it (or the row for a new tempo
change), drag one along the song. In the bars, click to seek and drag to set the loop's range or
move its ends. Right-click the ruler for a region over the loop, looping a region, a time
signature change and deleting. The transport's COUNT sets a count-in.

A track header's A lists the controls it can automate; each one picked gets a lane under the
track. Click a lane for a point, drag a point, right-click one to delete it; X hides the lane.

Double-click a MIDI clip for its notes in the piano roll, which has the height to itself until its
back button or Esc. Drag on an empty row to draw a note, a note to move it, its right end to
stretch it (on the grid unless Alt is held); right-click or Del deletes one, the arrows transpose
the picked note (Shift an octave), the bars under the notes are their velocities, and Q quantizes
the clip to the grid chosen at the top.

## Audio files

`DawKitFlacWriter.write(path, samples, channels, rate, bits)` writes 16 or 24-bit FLAC (independent channels, fixed predictors, Rice coding; no LPC or stereo decorrelation, so about a fifth bigger than the reference encoder; exact, with the MD5, and `flac -t` accepts it).

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

## Time-stretch and pitch-shift

`DawKitStretch.stretch(samples, channels, rate, ratio)` changes a sound's length (0.25 to 4 times) and keeps its pitch
(WSOLA); `pitch_shift(samples, channels, rate, semitones)` changes its pitch (±24) and keeps its length. Offline, on
interleaved floats; one grain offset for all channels, so a stereo image holds. Not yet played live by the lanes.

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
- **Loading.** `load` makes a plugin on the calling thread. `begin_load(info, state, rate,
  max_block)` makes it on a thread of its own -- loaded, set from `state`, activated -- while the
  main thread carries on (a Windows plugin through yabridge takes five seconds and more, as it
  starts a Wine process); `is_loading()`, from the main thread, says when it is done and takes it
  over (`is_loaded`, or `get_error`), `wait_loaded()` waits. One plugin is made at a time, whoever
  asks. Until it is taken over the plugin is not pumped, run or shown, `info`, `is_instrument` and
  `get_state` answer as it was asked for, its loading thread stands in for the main thread (CLAP's
  thread check says so), and the timers and descriptors it asks the run loop for are held until it
  is taken over. LV2 plugins are still made on the main thread inside `begin_load`: lilv's world is
  shared by every LV2 plugin and read from the main thread by their windows and parameter words,
  and is not made for two threads. `shown_params(limit)` lists the parameters worth showing (a
  VST3 lists two thousand MIDI controller slots after its real ones).
- **Opening a window off the main thread.** A Windows plugin through yabridge (its library says
  `yabridge_version`; `HostedPlugin::is_bridged`) takes seconds to open its window, which
  yabridge's Wine host makes, in its own process, on its own X connection. `editor_open` makes the
  engine's window on the main thread (its X connection is the main thread's) and asks the plugin
  for its window from a thread of its own, under the same lock as loading and standing in for the
  main thread; `editor_is_open` is true and `editor_opening` says so until then, there is nothing
  to capture, input is not sent, and the plugin's own main-thread work waits. A window closed
  while it opens is closed once it has; one that would not open is closed, `get_error` saying
  why. Every other plugin's window opens on the main thread: its toolkit makes X windows on a
  connection of its own and works them from the thread that made them (JUCE and iPlug take it for
  their message thread), which must be the one that pumps them.
- **Effects.** A `DawKitPluginEffect` goes on a bus like any AudioEffect. Put on several buses that
  play the same lane (a track's, its sends', its cue's), it runs the plugin once a block, told apart
  by the transport's clock, and the other buses hear what it made.
- **Instruments.** `DawKitLane.set_instrument(plugin)` and `set_notes(notes)` play a lane's notes
  through the plugin, each on its sample, through loops and jumps (whatever was sounding stops), and
  notes played live on the plugin sound through the lane whether the song plays or not.
- **Windows.** A plugin's window is embedded in a window of the engine's, kept out of sight;
  `editor_capture()` reads it into `editor_image()`, and `editor_pointer_*`, `editor_wheel` and
  `editor_key` send input into it, so a host shows the window wherever it likes (a texture in 3D,
  a panel) and nothing appears on the desktop. On Linux that is an X11 window, read with
  XGetImage, kept off every screen -- except on Hyprland, which keeps no X window off its screens
  (one put at x = -30000 is shown at x = -1, in the desktop's corner): there it is an ordinary
  window, class `dawkit-plugin-window`, that a hook the engine installs in Hyprland's Lua
  (`hl.on("window.open_early")`, through `hyprctl eval`) puts on the special workspace `dawkit`,
  floating and unfocused, as it opens. `DAWKIT_PLUGIN_DISPLAY=xvfb` instead starts a private Xvfb
  (xorg-server-xvfb) for plugins' windows, ended with the process, and `DAWKIT_PLUGIN_DISPLAY=:N`
  uses a display already running; either is set as `DISPLAY` before the first plugin loads (the
  game's own window is open by then and stays where it is; programs the game starts later inherit
  it). On Windows it is a tool window read with
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
  so on Hyprland, while a plugin loads and while any plugin's window is open, the same hook puts a
  window that opens untitled or titled "menu", from a process the engine's started (yabridge's
  Wine host) or one drawing in a window of the engine's, on `dawkit` too, and it is read and worked
  there. A titled one (an activation, a licence, a file to open) is left on the desktop to be
  answered, and `DawKitPlugin.take_desktop_windows()` names it so a host can say so. The hook is
  renewed every 2 seconds while needed and goes quiet 8 seconds after it was last renewed, so
  other programs' windows are never touched, and nothing stays hidden after a crash. A Wine plugin
  also closes its menus when its window is not the active one, so from a click until its menus
  close the engine names the plugin's window in `_NET_ACTIVE_WINDOW` (a thread of its own names
  it again whenever the window manager changes it). Set `DAWKIT_NO_HYPRLAND_RULE` to leave the
  window manager alone; the engine's windows are then off-screen ones again, and such menus appear
  wherever it puts them.

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

MIT. See LICENSE. Third-party material is listed in THIRD_PARTY_NOTICES.md.
