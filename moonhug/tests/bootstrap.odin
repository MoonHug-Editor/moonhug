package tests

// Shared world bootstrap lives in tests/common so per-package test suites
// (moonhug/packages/<name>/tests — docs/Plugins.md) can import it too. The
// central suite keeps the short names through these aliases.
//
// RULE: this package never imports "moonhug:packages/..." — core tests test core;
// a package's tests live WITH the package and die with it on uninstall.

import common "common"

TestCtx :: common.TestCtx
setup :: common.setup
teardown :: common.teardown
