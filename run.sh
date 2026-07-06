#!/usr/bin/env sh
set -e

# Prebuild: run all code generators (menu_gen, etc.)
odin run moonhug/prebuild || exit 1

# Run assets package (uses -ignore-unknown-attributes for custom menu attributes).
# -out names the binary MoonHug so macOS (App Switcher, menu bar) shows that
# instead of the package name "editor".
mkdir -p builds
odin run moonhug/editor -ignore-unknown-attributes -out:builds/MoonHug
