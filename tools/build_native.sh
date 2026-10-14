#!/usr/bin/env bash
# Build dawkit's native core (native/, a GDExtension) into addons/dawkit/bin. Incremental: a
# build with nothing changed takes a second. Needs cmake and a C++17 compiler; for windows,
# MinGW-w64 (x86_64-w64-mingw32-g++); for android (arm64, the Quest), the Android NDK, found at
# $ANDROID_NDK_ROOT or the newest under $ANDROID_HOME/ndk (default ~/Android/Sdk).
#
#   tools/build_native.sh                    # linux, template_debug: what the editor and tests load
#   tools/build_native.sh windows release    # a platform, and debug, release or all
set -euo pipefail
PLATFORM="${1:-linux}"
WHICH="${2:-debug}"
cd "$(dirname "$0")/../native"
[ -f godot-cpp/CMakeLists.txt ] || git -C .. submodule update --init native/godot-cpp
# The API of the Godot that will load it, which godot-cpp generates its bindings from.
[ -f extension_api.json ] || godot --headless --dump-extension-api >/dev/null 2>&1
case "$PLATFORM" in
  linux) TOOLCHAIN=() ;;
  windows) TOOLCHAIN=(-DCMAKE_TOOLCHAIN_FILE=cmake/mingw-w64.cmake) ;;
  android)
    NDK="${ANDROID_NDK_ROOT:-$(ls -d "${ANDROID_HOME:-$HOME/Android/Sdk}"/ndk/* 2>/dev/null | sort -V | tail -1)}"
    [ -f "$NDK/build/cmake/android.toolchain.cmake" ] || { echo "no Android NDK (set ANDROID_NDK_ROOT)" >&2; exit 2; }
    # arm64 is every standalone headset this is for; API 29 is the oldest a Quest runs.
    TOOLCHAIN=(-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
        -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29) ;;
  *) echo "platform: linux, windows or android, not '$PLATFORM'" >&2; exit 2 ;;
esac
case "$WHICH" in
  debug) TARGETS=(template_debug) ;;
  release) TARGETS=(template_release) ;;
  all) TARGETS=(template_debug template_release) ;;
  *) echo "which: debug, release or all, not '$WHICH'" >&2; exit 2 ;;
esac
for target in "${TARGETS[@]}"; do
  # The linux debug build keeps the directory it always had, so an existing tree stays warm.
  dir=build
  [ "$PLATFORM-$target" = "linux-template_debug" ] || dir="build-$PLATFORM-$target"
  cmake -S . -B "$dir" -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET="$target" "${TOOLCHAIN[@]}" >/dev/null
  cmake --build "$dir" -j"$(nproc)" >/dev/null
done
