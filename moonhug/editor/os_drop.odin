package editor

// Files dragged from the OS file browser onto the editor (SDL's drop events).
//
// - While the drag is over the editor, SDL sends its position. imgui gets it
//   as the mouse's, since the OS sends no mouse motion during a drag, so a
//   window knows what is under the pointer the usual way. os_drop_hovering
//   says a drag is there. What it carries is not known before the release.
// - On the release SDL sends each file, then that the drop is complete. For
//   that one frame os_drop_files has the paths, and the window under the
//   pointer that wants them calls os_drop_take.
//
// The Project window takes them: a folder under the pointer, or the folder it
// shows, gets a copy of each (project_rows.odin).

import "base:runtime"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import im "moonhug:external/odin-imgui"
import "moonhug:libs/log"

@(private = "file")
_os_drop: struct {
	over_ns: i64,             // when the last position came, 0 for none
	files:   [dynamic]string, // owned, default allocator
	ready:   bool,            // the drop is complete: this frame's windows may take the files
	taken:   bool,
}

// A drag stays "over" this long after its last position: SDL sends no event
// when a drag leaves the editor without a drop.
@(private = "file")
_OS_DROP_OVER_NS :: i64(400_000_000)

// The frame loop's event callback gives every SDL event here.
os_drop_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .DROP_BEGIN:
		_os_drop_clear()
	case .DROP_POSITION:
		os_drop_over(_os_drop_point(e))
	case .DROP_FILE:
		if e.drop.data == nil do return
		os_drop_over(_os_drop_point(e))
		context.allocator = runtime.default_allocator()
		append(&_os_drop.files, strings.clone(string(e.drop.data)))
	case .DROP_COMPLETE:
		os_drop_complete()
	}
}

// The event's point as imgui's mouse position: with floating windows on,
// imgui's positions are the screen's, and SDL's are the window's.
@(private = "file")
_os_drop_point :: proc(e: ^sdl.Event) -> [2]f32 {
	p := [2]f32{e.drop.x, e.drop.y}
	if .ViewportsEnable in im.GetIO().ConfigFlags {
		if window := sdl.GetWindowFromID(e.drop.windowID); window != nil {
			wx, wy: i32
			sdl.GetWindowPosition(window, &wx, &wy)
			p += {f32(wx), f32(wy)}
		}
	}
	return p
}

// A drag from the OS is at `point`, in imgui's coordinates.
os_drop_over :: proc(point: [2]f32) {
	_os_drop.over_ns = time.now()._nsec
	im.IO_AddMousePosEvent(im.GetIO(), point.x, point.y)
}

// One more file of the drop in progress, for a drop that does not come from
// SDL (the bridge's input tool).
os_drop_add_file :: proc(path: string) {
	context.allocator = runtime.default_allocator()
	append(&_os_drop.files, strings.clone(path))
}

// Every file of the drop came.
os_drop_complete :: proc() {
	_os_drop.over_ns = 0
	_os_drop.ready = len(_os_drop.files) > 0
	_os_drop.taken = false
}

// A drag from the OS is over the editor, not released yet.
os_drop_hovering :: proc() -> bool {
	return !_os_drop.ready && _os_drop.over_ns != 0 && time.now()._nsec - _os_drop.over_ns < _OS_DROP_OVER_NS
}

// The files just dropped, for the one frame after the release. nil otherwise.
os_drop_files :: proc() -> []string {
	if !_os_drop.ready || _os_drop.taken do return nil
	return _os_drop.files[:]
}

// A window took the dropped files.
os_drop_take :: proc() {
	_os_drop.taken = true
}

// After the windows drew: files no window took are let go.
os_drop_frame_end :: proc() {
	if !_os_drop.ready do return
	if !_os_drop.taken do log.info("Drop files on a folder of the Project window to copy them into the project")
	_os_drop_clear()
}

@(private = "file")
_os_drop_clear :: proc() {
	for f in _os_drop.files do delete(f, runtime.default_allocator())
	clear(&_os_drop.files)
	_os_drop.ready = false
	_os_drop.taken = false
}

os_drop_shutdown :: proc() {
	_os_drop_clear()
	delete(_os_drop.files)
	_os_drop.files = nil
}
