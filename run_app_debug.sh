#!/usr/bin/env sh
set -e

cd "$(cd "$(dirname "$0")" && pwd)/moonhug"

odin run app -ignore-unknown-attributes -debug
