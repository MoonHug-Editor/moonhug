#!/usr/bin/env sh
set -e

# Prebuild: run all code generators (menu_gen, etc.)
odin run moonhug/prebuild || exit 1

# Recompile GPU shaders when the toolchain is present (compiled blobs are
# committed, so this is optional — see docs/SDL3Renderer.md).
if command -v glslc >/dev/null && command -v spirv-cross >/dev/null; then
    sh moonhug/engine/gfx/shaders/compile.sh
fi

# Build then exec (uses -ignore-unknown-attributes for custom menu attributes).
# -out names the binary MoonHug so macOS (App Switcher, menu bar) shows that
# instead of the package name "editor". Build+exec (NOT `odin run`) so the ~1GB
# compiler process exits before the editor runs instead of lingering to wait().
mkdir -p builds
odin build moonhug/editor -ignore-unknown-attributes -collection:moonhug=moonhug -out:builds/MoonHug
exec builds/MoonHug
