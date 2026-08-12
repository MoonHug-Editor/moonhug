#!/usr/bin/env sh
set -e

# Prune imports of removed package generators (moonhug/packages/*/gen) —
# a stale import fails the prebuild compile before prebuild can heal the
# file itself. Prebuild owns generating the full set (and exits asking for a
# re-run when a NEW generator appears).
odin run moonhug/prebuild/prune_package_gens || exit 1

# Prebuild: run all code generators (menu_gen, etc.)
odin run moonhug/prebuild -collection:moonhug=moonhug || exit 1

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
