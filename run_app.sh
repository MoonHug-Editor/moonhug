#!/usr/bin/env sh
set -e

# Run from the repo root (the app normalizes its own cwd to moonhug/), so the
# packages: collection flag is the same spelling as every other build.
cd "$(cd "$(dirname "$0")" && pwd)"

# Build+exec (NOT `odin run`) so the ~1GB compiler process exits before the app
# runs instead of lingering to wait() on it.
mkdir -p builds
odin build moonhug/app -ignore-unknown-attributes -collection:packages=moonhug/packages -out:builds/app
exec builds/app
