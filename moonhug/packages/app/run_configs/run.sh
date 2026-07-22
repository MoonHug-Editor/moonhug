#!/usr/bin/env sh
# Run configuration (docs/Plugins.md): the editor's Play dropdown lists every
# packages/*/run_configs/*.sh by filename and runs the picked one from the
# REPO ROOT, appending its args (the live-scene snapshot path) — forward them
# to the binary with "$@". Works identically from a terminal.
set -e
mkdir -p builds
odin build moonhug/packages/app -ignore-unknown-attributes -collection:packages=moonhug/packages -out:builds/app
exec builds/app "$@"
