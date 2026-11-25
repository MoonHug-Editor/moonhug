package editor

// The debug editor's exit report. Every allocation that is not freed at exit
// and every bad free is grouped by where it was made, one line per place:
//
//   leak 12 x 3.4 KiB  moonhug/editor/window.odin:97 editor::load_editor_settings
//
// Nothing is printed when nothing leaked.
//
// The place is the allocation's own location, which for memory a library made
// (json.unmarshal, strings.clone) is a line inside that library. Started with
// MH_LEAK_TRACE=1, the editor keeps a stack trace per allocation instead and
// names the repo's line behind the library's: for hunting such a leak. The
// traces make every allocation slower, opening a scene several times over,
// so they are off by default.
//
// Settings live for the whole run and are never freed, which is right. So the
// report would list them on every exit and bury the real leaks. Before it
// prints, leak_free_settings frees what the settings own: the editor's own
// (editor_settings) and every @(user_settings), @(system_settings) and
// project settings var.

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import core "moonhug:libs/core"

@(private = "file") _traced: bool
@(private = "file") _plain: mem.Tracking_Allocator
@(private = "file") _traces: trace.Tracking_Allocator

// Wraps `backing` in a tracking allocator for the whole run of a debug
// editor: the plain one, or the one with stack traces under MH_LEAK_TRACE.
leak_tracking_begin :: proc(backing: runtime.Allocator) -> runtime.Allocator {
	_traced = os.get_env("MH_LEAK_TRACE", context.temp_allocator) != ""
	if _traced {
		trace.tracking_allocator_init(&_traces, backing)
		_traces.bad_free_callback = trace.tracking_allocator_bad_free_callback_add_to_array
		return trace.tracking_allocator(&_traces)
	}
	mem.tracking_allocator_init(&_plain, backing)
	_plain.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	return mem.tracking_allocator(&_plain)
}

// At exit: frees the settings, prints the report, and drops the tracker.
leak_tracking_end :: proc() {
	leak_free_settings()
	leak_report_print()
	if _traced do trace.tracking_allocator_destroy(&_traces)
	else do mem.tracking_allocator_destroy(&_plain)
}

// Whether the tracker handed out `block` and it is not freed yet: a settings
// string still at its default literal is not.
@(private = "file")
_tracked :: proc(block: rawptr) -> bool {
	if _traced {
		_, ok := _traces.allocation_map[block]
		return ok
	}
	_, ok := _plain.allocation_map[block]
	return ok
}

leak_free_settings :: proc() {
	core.value_free(&editor_settings, typeid_of(type_of(editor_settings)), _tracked)
	_free_user_settings(_tracked)
	_free_system_settings(_tracked)
	_free_project_settings(_tracked)
}

@(private = "file")
_Leak_Site :: struct {
	where_: string,
	count:  int,
	bytes:  int,
	bad:    bool,
}

// A path from the repo root when it is in the repo, else as it is.
@(private = "file")
_repo_path :: proc(path: string) -> (string, bool) {
	if strings.contains(path, "/moonhug/external/") do return path, false
	if i := strings.index(path, "/plugins/"); i >= 0 do return path[i + 1:], true
	if i := strings.index(path, "/moonhug/"); i >= 0 do return path[i + 1:], true
	return path, false
}

@(private = "file")
_site_of_location :: proc(loc: runtime.Source_Code_Location) -> string {
	path, _ := _repo_path(loc.file_path)
	return fmt.tprintf("%s:%d %s", path, loc.line, loc.procedure)
}

// The first frame of `bt` in the repo's code, else the allocation's own place.
@(private = "file")
_site_of_trace :: proc(bt: trace.Capture_Const, fallback: runtime.Source_Code_Location) -> string {
	frames, err := trace.resolve(bt, context.temp_allocator, context.temp_allocator)
	if err == nil do for f in frames {
		if path, ours := _repo_path(f.file_path); ours do return fmt.tprintf("%s:%d %s", path, f.line, f.procedure)
	}
	return _site_of_location(fallback)
}

@(private = "file")
_add :: proc(sites: ^map[string]_Leak_Site, where_: string, bytes: int, bad: bool) {
	key := fmt.tprintf("%v %s", bad, where_)
	s := sites[key]
	sites[key] = {where_ = where_, count = s.count + 1, bytes = s.bytes + bytes, bad = bad}
}

leak_report_print :: proc() {
	sites := make(map[string]_Leak_Site, context.temp_allocator)
	if _traced {
		for _, e in _traces.allocation_map do _add(&sites, _site_of_trace(e.backtrace, e.location), e.size, false)
		for e in _traces.bad_free_array do _add(&sites, _site_of_trace(e.backtrace, e.location), 0, true)
	} else {
		for _, e in _plain.allocation_map do _add(&sites, _site_of_location(e.location), e.size, false)
		for e in _plain.bad_free_array do _add(&sites, _site_of_location(e.location), 0, true)
	}
	if len(sites) == 0 do return
	list := make([dynamic]_Leak_Site, context.temp_allocator)
	for _, s in sites do append(&list, s)
	slice.sort_by(list[:], proc(a, b: _Leak_Site) -> bool {
		if a.bad != b.bad do return a.bad
		if a.bytes != b.bytes do return a.bytes > b.bytes
		return a.where_ < b.where_
	})
	total, count, in_library := 0, 0, false
	for s in list {
		if s.bad {
			fmt.eprintfln("bad free %d x  %s", s.count, s.where_)
			continue
		}
		fmt.eprintfln("leak %d x %v  %s", s.count, _bytes(s.bytes), s.where_)
		total += s.bytes
		count += s.count
		if !strings.has_prefix(s.where_, "moonhug/") && !strings.has_prefix(s.where_, "plugins/") do in_library = true
	}
	if count > 0 do fmt.eprintfln("leaks: %d allocations, %v, at %d places", count, _bytes(total), len(list))
	if in_library && !_traced do fmt.eprintln("leaks: a place inside a library: start the editor with MH_LEAK_TRACE=1 to name the repo line behind it")
}

@(private = "file")
_bytes :: proc(n: int) -> string {
	if n < 1024 do return fmt.tprintf("%d B", n)
	if n < 1024 * 1024 do return fmt.tprintf("%.1f KiB", f64(n) / 1024)
	return fmt.tprintf("%.1f MiB", f64(n) / (1024 * 1024))
}
