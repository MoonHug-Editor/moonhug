package window

// Plugin-openable editor windows (docs/Plugins.md). A window is DECLARED with
// @(editor_window={id, title, width, height}) on its content-draw proc —
// prebuild registers every declaration here — and OPENED by id, usually from a
// @(menu_item) proc, the way Unity's [MenuItem] calls EditorWindow.GetWindow.
//
// State: the registry and open list live here for the process lifetime (reopen
// from the menu after a restart). imgui.ini persists dock position and size by
// title; width/height from the attribute apply only when imgui.ini has no
// entry yet (Cond.FirstUseEver). Window CONTENTS live in the owning plugin.
//
// An editor subpackage like menu/inspector/undo: plugin editor/ packages import
// it, the editor root draws it once per frame (draw_all).

import im "moonhug:external/odin-imgui"
import "moonhug:engine/log"

Draw_Proc :: proc()

_Registered :: struct {
	id:           string,  // stable handle from the attribute
	title:        cstring, // window title, also the imgui id
	draw:         Draw_Proc,
	default_size: im.Vec2, // {} = imgui's default
}

_Open :: struct {
	reg:  int, // index into _registry
	open: bool,
}

_registry: [dynamic]_Registered
_open_windows: [dynamic]_Open
_focus_request: int = -1 // registry index to focus next frame

// Called by the generated _register_editor_windows (editor_window_gen). All
// strings are literals in generated code — nothing is cloned.
register :: proc(id: string, title: cstring, draw: Draw_Proc, width, height: f32) {
	for &r in _registry {
		if r.id == id {
			log.errorf("editor_window: duplicate id %q (%s ignored)", id, title)
			return
		}
	}
	append(&_registry, _Registered{
		id           = id,
		title        = title,
		draw         = draw,
		default_size = {width, height},
	})
}

// The ids of every currently open window — the editor persists these in
// editor_settings so a session reopens what was open (imgui.ini already
// keeps position and size, but not whether the window existed).
open_ids :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(_open_windows), allocator)
	for &e in _open_windows {
		if e.open do append(&out, _registry[e.reg].id)
	}
	return out[:]
}

// Reopen the windows named by a previous open_ids — unknown ids (a package
// that is no longer installed) are skipped quietly, unlike `open`.
open_saved :: proc(ids: []string) {
	for id in ids {
		for &r, ri in _registry {
			if r.id != id do continue
			already := false
			for &e in _open_windows do if e.reg == ri do already = true
			if !already do append(&_open_windows, _Open{reg = ri, open = true})
			break
		}
	}
}

// Show the window declared under `id`, or focus it if already open.
open :: proc(id: string) {
	for &r, ri in _registry {
		if r.id != id do continue
		for &e in _open_windows {
			if e.reg == ri {
				_focus_request = ri
				return
			}
		}
		append(&_open_windows, _Open{reg = ri, open = true})
		return
	}
	log.errorf("editor_window: unknown id %q (declare it with @(editor_window={{id=...}}))", id)
}

close :: proc(id: string) {
	for &e in _open_windows {
		if _registry[e.reg].id == id do e.open = false
	}
}

is_open :: proc(id: string) -> bool {
	for &e in _open_windows {
		if _registry[e.reg].id == id do return true
	}
	return false
}

// One call per editor frame, after the built-in views. Removal happens here,
// the frame after the close button flips `open`.
draw_all :: proc() {
	for i := len(_open_windows) - 1; i >= 0; i -= 1 {
		e := &_open_windows[i]
		if !e.open {
			ordered_remove(&_open_windows, i)
			continue
		}
		r := &_registry[e.reg]
		if r.default_size != {} {
			im.SetNextWindowSize(r.default_size, .FirstUseEver)
		}
		if _focus_request == e.reg {
			im.SetNextWindowFocus()
			_focus_request = -1
		}
		// NoCollapse matches every built-in view — no collapse triangle when
		// the window floats.
		if im.Begin(r.title, &e.open, {.NoCollapse}) {
			r.draw()
		}
		im.End()
	}
}

shutdown :: proc() {
	delete(_registry)
	_registry = nil
	delete(_open_windows)
	_open_windows = nil
}
