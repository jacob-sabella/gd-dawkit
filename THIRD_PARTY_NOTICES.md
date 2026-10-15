# Third-party notices

dawkit's own code is MIT licensed (see LICENSE). It includes the third-party material below. Each
part keeps its own licence, whose full text is in the directory named, and a build or a copy of the
source that includes that part must keep that notice with it.

## Plugin format headers (native core)

`native/third_party/` holds only the interface headers of the plugin formats dawkit hosts. They are
compiled into the native core (`addons/dawkit/bin`) and `dawkit_scan`; no hosting code from any SDK
is used (the hosts are dawkit's own, in `native/src/plugins`).

| Part | Directory | Licence | Copyright |
|---|---|---|---|
| CLAP | `native/third_party/clap` | MIT (`LICENSE`) | 2021 Alexandre Bique |
| VST3 interfaces (3.8) | `native/third_party/vst3` | MIT (`LICENSE.txt`) | 2025 Steinberg Media Technologies GmbH |
| LV2 | `native/third_party/lv2` | ISC (`COPYING`) | 2006-2012 Steve Harris, David Robillard; 2000-2002 Richard W.E. Furse, Paul Barton-Davis, Stefan Westerfeld |
| lilv (header) | `native/third_party/lilv` | ISC (`COPYING`) | 2011-2026 David Robillard |

lilv itself is not shipped or linked: only its header is here, and the library is opened at run
time if the system has it.

## Godot

dawkit runs inside the Godot Engine (MIT, godotengine.org). The native core is built with
godot-cpp (MIT, Copyright (c) 2017-present Godot Engine contributors), a git submodule at
`native/godot-cpp` whose own `LICENSE.md` applies; `native/extension_api.json` is the engine's API
description it is generated from. A build that ships the core must include Godot's and godot-cpp's
MIT notices.

## Tests only

The material below ships only in `tests/`, is used only by dawkit's own checks, and is not part of
the addon (`addons/dawkit`).

### DAWproject schema and examples

`tests/fixtures/dawproject/Project.xsd`, `MetaData.xsd`, `bitwig_readme_example.xml` and the
files in `tests/fixtures/dawproject/reference/` are from
[github.com/bitwig/dawproject](https://github.com/bitwig/dawproject), Copyright (c) 2020 Bitwig,
under the MIT License; the full text is in `tests/fixtures/dawproject/LICENSE`. dawkit reads and
writes the DAWproject format from its specification; it copies none of the reference
implementation's code.

### Test sounds

`tests/fixtures/audio/` holds sounds made for these tests: the FLAC fixtures were encoded with
the reference `flac` 1.5 tool from WAVs generated here (the tool is not shipped or linked;
FLAC is decoded by dawkit's own code, written from RFC 9639).

### Test plugin

`native/test_plugin` is a CLAP (a gain and a sine instrument) written for the tests, built
against the CLAP headers above.
