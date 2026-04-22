#!/usr/bin/env sh
set -e

odin run moonhug/prebuild || exit 1

odin run moonhug/editor -ignore-unknown-attributes -debug
