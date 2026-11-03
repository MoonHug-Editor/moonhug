package inspector

// The row probe: for one frame, every row the inspector draws reports the
// field name it edits and the rectangle of the last widget it drew, so the
// MCP bridge's item_rect tool (editor/mcp_input.odin) can name a row by its
// field and get a point to drive input at. Armed per request: a frame nobody
// asked about records nothing.

import "base:runtime"
import "core:strings"
import im "moonhug:external/odin-imgui"

Row_Rect :: struct {
	window: string, // the imgui window the row drew in (a child carries its parent's name as a prefix)
	label:  string, // the field name the row edits
	min:    [2]f32, // the widget's rectangle, screen coordinates
	max:    [2]f32,
}

@(private = "file")
_probe: struct {
	armed: bool,
	rows:  [dynamic]Row_Rect,
}

// Records the rows of the next frame drawn. The rows of an earlier probe are dropped.
row_probe_arm :: proc() {
	_row_probe_clear()
	_probe.armed = true
}

// The rows recorded since the arm, and disarms. Valid until the next arm.
row_probe_take :: proc() -> []Row_Rect {
	_probe.armed = false
	return _probe.rows[:]
}

// Called by the row edit once the drawer has drawn: the last item is the row's widget.
row_probe_record :: proc(label: string) {
	if !_probe.armed do return
	ctx := im.GetCurrentContext()
	if ctx == nil || ctx.CurrentWindow == nil do return
	context.allocator = runtime.default_allocator()
	if _probe.rows == nil do _probe.rows = make([dynamic]Row_Rect)
	append(&_probe.rows, Row_Rect{
		window = strings.clone(string(ctx.CurrentWindow.Name)),
		label  = strings.clone(label),
		min    = im.GetItemRectMin(),
		max    = im.GetItemRectMax(),
	})
}

@(private = "file")
_row_probe_clear :: proc() {
	context.allocator = runtime.default_allocator()
	for r in _probe.rows {
		delete(r.window)
		delete(r.label)
	}
	clear(&_probe.rows)
}
