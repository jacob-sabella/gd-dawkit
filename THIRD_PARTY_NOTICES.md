# Third-party notices

dawkit's own code is MIT licensed (see LICENSE). It contains no third-party code. The material
below ships only in `tests/`, is used only by dawkit's own checks, and is not part of the addon
(`addons/dawkit`) that is distributed.

## DAWproject schema and examples

`tests/fixtures/dawproject/Project.xsd`, `MetaData.xsd`, `bitwig_readme_example.xml` and the
files in `tests/fixtures/dawproject/reference/` are from
[github.com/bitwig/dawproject](https://github.com/bitwig/dawproject), Copyright (c) 2020 Bitwig,
under the MIT License; the full text is in `tests/fixtures/dawproject/LICENSE`. dawkit reads and
writes the DAWproject format from its specification; it copies none of the reference
implementation's code.

## Test sounds

`tests/fixtures/audio/` holds sounds made for these tests: the FLAC fixtures were encoded with
the reference `flac` 1.5 tool from WAVs generated here (the tool is not shipped or linked;
FLAC is decoded by dawkit's own code, written from RFC 9639).

## Godot

dawkit runs inside the Godot Engine (MIT, godotengine.org). The GDExtension core, when built,
uses godot-cpp (MIT); a build that ships it must include Godot's and godot-cpp's MIT notices.
