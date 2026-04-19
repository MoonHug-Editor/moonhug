#!/usr/bin/env sh
set -e

odin test moonhug/tests -ignore-unknown-attributes -define:ODIN_TEST_THREADS=1
