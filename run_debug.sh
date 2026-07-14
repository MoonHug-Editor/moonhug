#!/usr/bin/env sh
set -e

odin run moonhug/prebuild || exit 1

mkdir -p builds
odin run moonhug/editor -ignore-unknown-attributes -debug -out:builds/MoonHug
