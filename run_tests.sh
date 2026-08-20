#!/usr/bin/env sh
set -e


odin test moonhug/tests -all-packages -ignore-unknown-attributes -collection:moonhug=moonhug -define:ODIN_TEST_THREADS=1
