#!/usr/bin/env sh
set -e

odin test moonhug/tests -ignore-unknown-attributes -collection:packages=moonhug/packages -define:ODIN_TEST_THREADS=1
