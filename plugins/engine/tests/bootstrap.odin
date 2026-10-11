package engine_tests

// The engine plugin's test suite. It runs through the central suite like every
// plugin's tests/ folder (docs/core/Plugins.md). The shared world bootstrap
// lives in moonhug:tests/common. These aliases keep the short names.

import common "moonhug:tests/common"

TestCtx :: common.TestCtx
setup :: common.setup
teardown :: common.teardown
setup_undo :: common.setup_undo
teardown_undo :: common.teardown_undo
find_transform_named :: common.find_transform_named
_remove_tree :: common.remove_tree

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
handles_test_view :: common.handles_test_view
handles_frame :: common.handles_frame
handles_drag :: common.handles_drag
handles_step :: common.handles_step
Handles_Keys :: common.Handles_Keys
