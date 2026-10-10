#!/usr/bin/env bash
# Build dawkit's native core (native/, a GDExtension) into addons/dawkit/bin. Incremental: a
# build with nothing changed takes a second. Needs cmake and a C++17 compiler.
set -euo pipefail
cd "$(dirname "$0")/../native"
[ -f godot-cpp/CMakeLists.txt ] || git -C .. submodule update --init native/godot-cpp
# The API of the Godot that will load it, which godot-cpp generates its bindings from.
[ -f extension_api.json ] || godot --headless --dump-extension-api >/dev/null 2>&1
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_debug >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
