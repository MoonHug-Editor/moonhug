#!/usr/bin/env sh
set -e

# See run.sh — removes imports of deleted package generators first.
odin run moonhug/prebuild/prune_package_gens || exit 1

odin run moonhug/prebuild -collection:moonhug=moonhug || exit 1

mkdir -p builds
# Build then exec the binary (NOT `odin run`): `odin run` keeps the ~1GB
# compiler process resident for the whole life of the app just to wait() on it.
# `exec` hands the shell's PID to the editor so no wrapper lingers either.
odin build moonhug/editor -ignore-unknown-attributes -collection:moonhug=moonhug -debug -out:builds/MoonHug
exec builds/MoonHug
