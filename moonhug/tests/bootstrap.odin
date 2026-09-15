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

// The field-row harness (common/field_row_harness.odin) lives there for the
// same reason: a package's custom rows are tested with the package.
Frame :: common.Frame
Row_Harness :: common.Row_Harness
row_replay :: common.row_replay
row_set_peers :: common.row_set_peers
frame_idle :: common.frame_idle
frame_press :: common.frame_press
frame_drag :: common.frame_drag
frame_release :: common.frame_release
frame_popup_write :: common.frame_popup_write
frame_popup_open :: common.frame_popup_open
frame_popup_drag :: common.frame_popup_drag
frame_popup_rest :: common.frame_popup_rest
frame_button_click :: common.frame_button_click
