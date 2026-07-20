#!/usr/bin/env sh
set -e

odin run moonhug/prebuild || exit 1

mkdir -p builds
# Build then exec the binary (NOT `odin run`): `odin run` keeps the ~1GB
# compiler process resident for the whole life of the app just to wait() on it.
# `exec` hands the shell's PID to the editor so no wrapper lingers either.
odin build moonhug/editor -ignore-unknown-attributes -collection:packages=moonhug/packages -debug -out:builds/MoonHug
exec builds/MoonHug
