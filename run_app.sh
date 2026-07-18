#!/usr/bin/env sh
set -e

# Run from the repo root (the app normalizes its own cwd to moonhug/), so the
# packages: collection flag is the same spelling as every other build.
cd "$(cd "$(dirname "$0")" && pwd)"

odin run moonhug/app -ignore-unknown-attributes -collection:packages=moonhug/packages
