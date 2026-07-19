#!/usr/bin/env sh
set -e


odin test moonhug/tests -all-packages -ignore-unknown-attributes -collection:packages=moonhug/packages -define:ODIN_TEST_THREADS=1
