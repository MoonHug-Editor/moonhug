#!/usr/bin/env sh
set -e

# Prebuild: run all code generators (menu_gen, etc.)
odin run moonhug/prebuild || exit 1

# Recompile GPU shaders when the toolchain is present (compiled blobs are
# committed, so this is optional — see docs/SDL3Renderer.md).
if command -v glslc >/dev/null && command -v spirv-cross >/dev/null; then
    sh moonhug/engine/gfx/shaders/compile.sh
fi

# Run assets package (uses -ignore-unknown-attributes for custom menu attributes).
# -out names the binary MoonHug so macOS (App Switcher, menu bar) shows that
# instead of the package name "editor".
mkdir -p builds
odin run moonhug/editor -ignore-unknown-attributes -out:builds/MoonHug
