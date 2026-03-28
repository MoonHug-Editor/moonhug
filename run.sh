#!/usr/bin/env sh
set -e

# Prebuild: run all code generators (menu_gen, etc.)
odin run moonhug/prebuild || exit 1

# Run assets package (uses -ignore-unknown-attributes for custom menu attributes)
odin run moonhug/editor -ignore-unknown-attributes
