#!/usr/bin/env sh
set -e

odin run moonhug/prebuild || exit 1

mkdir -p builds
odin run moonhug/editor -ignore-unknown-attributes -collection:packages=moonhug/packages -debug -out:builds/MoonHug
