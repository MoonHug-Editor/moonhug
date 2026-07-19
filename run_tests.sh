#!/usr/bin/env sh
set -e

FLAGS="-ignore-unknown-attributes -collection:packages=moonhug/packages -define:ODIN_TEST_THREADS=1"

# Central suite (never imports packages: — core tests test core).
odin test moonhug/tests $FLAGS

# Per-package suites (docs/Plugins.md): tests ship WITH the package and die
# with it on uninstall.
for t in moonhug/packages/*/tests; do
    [ -d "$t" ] || continue
    odin test "$t" $FLAGS
done
