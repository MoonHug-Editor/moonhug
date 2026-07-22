#!/usr/bin/env sh
# Debug build: the app captures call stacks for console log lines
# (ODIN_DEBUG-gated in the app process). See run.sh for the contract.
set -e
mkdir -p builds
odin build moonhug/packages/app -ignore-unknown-attributes -collection:moonhug=moonhug -debug -out:builds/app_debug
exec builds/app_debug "$@"
