package editor

// The debug editor's exit report. Every allocation that is not freed at exit
// and every bad free is grouped by the first place in the repo's own code on
// its stack, so an allocation made inside a library (json.unmarshal,
// strings.clone) is reported at the line that called it. One line per place:
//
//   leak 12 x 3.4 KiB  moonhug/editor/window.odin:210 editor_settings_load
//
// Nothing is printed when nothing leaked.
//
// Settings live for the whole run and are never freed, which is right. So the
// report would list them on every exit and bury the real leaks. Before it
// prints, leak_free_settings frees what the settings own: the editor's own
// (editor_settings) and every @(user_settings), @(system_settings) and
// project settings var.

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import core "moonhug:libs/core"
import "core:slice"
import "core:strings"

@(private = "file")
_Leak_Site :: struct {
	where_: string,
	count:  int,
	bytes:  int,
	bad:    bool,
}

// The first frame of `bt` in the repo's code, else the allocation's own place.
@(private = "file")
_leak_site :: proc(bt: trace.Capture_Const, fallback: runtime.Source_Code_Location) -> string {
	frames, err := trace.resolve(bt, context.temp_allocator, context.temp_allocator)
	if err == nil do for f in frames {
		path := f.file_path
		if path == "" || !strings.contains(path, "/moonhug/") && !strings.contains(path, "/plugins/") do continue
		if strings.contains(path, "/moonhug/external/") do continue
		if i := strings.index(path, "/moonhug/"); i >= 0 && !strings.contains(path[:i], "/plugins") do path = path[i + 1:]
		if i := strings.index(path, "/plugins/"); i >= 0 do path = path[i + 1:]
		return fmt.tprintf("%s:%d %s", path, f.line, f.procedure)
	}
	return fmt.tprintf("%s:%d %s", fallback.file_path, fallback.line, fallback.procedure)
}

leak_report_print :: proc(t: ^trace.Tracking_Allocator) {
	sites := make(map[string]_Leak_Site, context.temp_allocator)
	for _, e in t.allocation_map {
		w := _leak_site(e.backtrace, e.location)
		s := sites[w]
		sites[w] = {where_ = w, count = s.count + 1, bytes = s.bytes + e.size}
	}
	for e in t.bad_free_array {
		w := _leak_site(e.backtrace, e.location)
		sites[fmt.tprintf("bad %s", w)] = {where_ = w, count = sites[fmt.tprintf("bad %s", w)].count + 1, bad = true}
	}
	if len(sites) == 0 do return
	list := make([dynamic]_Leak_Site, context.temp_allocator)
	for _, s in sites do append(&list, s)
	slice.sort_by(list[:], proc(a, b: _Leak_Site) -> bool {
		if a.bad != b.bad do return a.bad
		if a.bytes != b.bytes do return a.bytes > b.bytes
		return a.where_ < b.where_
	})
	total, count := 0, 0
	for s in list do if !s.bad {
		total += s.bytes
		count += s.count
	}
	for s in list {
		if s.bad do fmt.eprintfln("bad free %d x  %s", s.count, s.where_)
		else do fmt.eprintfln("leak %d x %v  %s", s.count, _bytes(s.bytes), s.where_)
	}
	if count > 0 do fmt.eprintfln("leaks: %d allocations, %v, at %d places", count, _bytes(total), len(list))
}

@(private = "file")
_bytes :: proc(n: int) -> string {
	if n < 1024 do return fmt.tprintf("%d B", n)
	if n < 1024 * 1024 do return fmt.tprintf("%.1f KiB", f64(n) / 1024)
	return fmt.tprintf("%.1f MiB", f64(n) / (1024 * 1024))
}

@(private = "file")
_tracker: trace.Tracking_Allocator

@(private = "file")
_track: ^trace.Tracking_Allocator

// Wraps `backing` in a tracking allocator that keeps a stack trace per
// allocation, for the whole run of a debug editor.
leak_tracking_begin :: proc(backing: runtime.Allocator) -> runtime.Allocator {
	trace.tracking_allocator_init(&_tracker, backing)
	_tracker.bad_free_callback = trace.tracking_allocator_bad_free_callback_add_to_array
	return trace.tracking_allocator(&_tracker)
}

// At exit: frees the settings, prints the report, and drops the tracker.
leak_tracking_end :: proc() {
	leak_free_settings(&_tracker)
	leak_report_print(&_tracker)
	trace.tracking_allocator_destroy(&_tracker)
}

// Whether the tracking allocator handed out `block` and it is not freed yet:
// a settings string still at its default literal is not.
@(private = "file")
_tracked :: proc(block: rawptr) -> bool {
	_, ok := _track.allocation_map[block]
	return ok
}

leak_free_settings :: proc(t: ^trace.Tracking_Allocator) {
	_track = t
	defer _track = nil
	core.value_free(&editor_settings, typeid_of(type_of(editor_settings)), _tracked)
	_free_user_settings(_tracked)
	_free_system_settings(_tracked)
	_free_project_settings(_tracked)
}
