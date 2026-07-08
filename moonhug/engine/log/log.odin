package mh_log

import "base:builtin"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Level :: enum {
	Info,
	Warning,
	Error,
}

Entry :: struct {
	id:       u64, // monotonically increasing; stable selection key for the console
	level:    Level,
	message:  string,
	loc:      runtime.Source_Code_Location,
	time:     time.Time,
	owns_loc: bool,     // remote (app-process) entries own their loc strings
	stack:    []string, // call stack, captured in debug builds only; owned lines
}

MAX_ENTRIES :: 100

// Machine-readable stdout format:
//   "@MHLOG|<level>|<time_ns>|<file>|<line>|<proc>|<stack>|<msg>"
// <time_ns> is the sender's unix-nano log time (entries must show when the
// app logged, not when the editor read the pipe). <stack> is call-stack
// frames joined by STACK_SEP (empty in non-debug builds — capture is
// ODIN_DEBUG-gated in the sending process, same rule as the editor). The app
// process sets stdout_tagged so the editor's pipe reader can parse its log
// lines back into console entries; untagged processes just print the message.
STDOUT_TAG :: "@MHLOG|"
STACK_SEP :: "\x1f" // unit separator; never appears in symbol names
stdout_tagged: bool

entries: [dynamic]Entry
_next_id: u64

// Entries arriving from other threads (the editor's play-thread pipe reader)
// land here and are moved into `entries` by drain() on the UI thread — the UI
// iterates `entries` unlocked every frame, so it must never be written directly
// from another thread.
_pending: [dynamic]Entry
_pending_mutex: sync.Mutex

info :: proc(msg: string, loc := #caller_location) {
	_log(.Info, msg, loc)
}

warning :: proc(msg: string, loc := #caller_location) {
	_log(.Warning, msg, loc)
}

error :: proc(msg: string, loc := #caller_location) {
	_log(.Error, msg, loc)
}

// One capture serves both sinks: stdout (read-only, joined into the tagged
// line) and the entry (takes ownership).
_log :: proc(level: Level, msg: string, loc: runtime.Source_Code_Location) {
	stack := _capture_stack(_log_alloc())
	_emit_stdout(level, msg, loc, stack)
	append_entry(level, msg, loc, stack)
}

infof :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	info(fmt.tprintf(fmt_str, ..args), loc)
}

warningf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	warning(fmt.tprintf(fmt_str, ..args), loc)
}

errorf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	error(fmt.tprintf(fmt_str, ..args), loc)
}

_emit_stdout :: proc(level: Level, msg: string, loc: runtime.Source_Code_Location, stack: []string) {
	if stdout_tagged {
		joined := strings.join(stack, STACK_SEP, context.temp_allocator)
		fmt.printfln("%s%d|%d|%s|%d|%s|%s|%s", STDOUT_TAG, int(level), time.now()._nsec, loc.file_path, loc.line, loc.procedure, joined, msg)
	} else {
		fmt.println(msg)
	}
}

clear :: proc() {
	for entry in entries {
		_entry_destroy(entry)
	}
	builtin.clear(&entries)
}

shutdown :: proc() {
	sync.mutex_lock(&_pending_mutex)
	for e in _pending {
		_entry_destroy(e)
	}
	builtin.clear(&_pending)
	sync.mutex_unlock(&_pending_mutex)

	clear()
	delete(entries)
	delete(_pending)
}

// All long-lived log data (entries, their strings, the arrays themselves) is
// allocated with the DEFAULT allocator explicitly: log calls happen under
// arbitrary caller contexts (the editor wraps its context in a tracking
// allocator in debug), while clear/drain/shutdown run under others — freeing
// through a different allocator than the one that allocated panics.
_log_alloc :: proc() -> runtime.Allocator {
	return runtime.default_allocator()
}

_inited: bool
_ensure_init :: proc() {
	if _inited do return
	_inited = true
	entries = make([dynamic]Entry, 0, 16, _log_alloc())
	_pending = make([dynamic]Entry, 0, 8, _log_alloc())
}

// `stack` (if given) must be allocated with _log_alloc(); the entry owns it.
// nil = capture here.
append_entry :: proc(level: Level, msg: string, loc := #caller_location, stack: []string = nil) {
	_ensure_init()
	_make_room()
	_next_id += 1
	a := _log_alloc()
	s := stack
	if s == nil {
		s = _capture_stack(a)
	}
	append(&entries, Entry{
		id      = _next_id,
		level   = level,
		message = strings.clone(msg, a),
		loc     = loc,
		time    = time.now(),
		stack   = s,
	})
}

// Thread-safe entry point for log lines parsed off the running app's stdout.
// Clones with the default allocator (never the caller thread's temp) and only
// touches the pending queue; drain() publishes on the UI thread.
intake_remote :: proc(level: Level, t: time.Time, file_path: string, line: int, procedure: string, msg: string, stack: []string = nil) {
	a := _log_alloc()
	e := Entry{
		level   = level,
		message = strings.clone(msg, a),
		loc     = {
			file_path = strings.clone(file_path, a),
			procedure = strings.clone(procedure, a),
			line      = i32(line),
		},
		time     = t if t._nsec != 0 else time.now(),
		owns_loc = true,
	}
	if len(stack) > 0 {
		frames := make([]string, len(stack), a)
		for s, i in stack {
			frames[i] = strings.clone(s, a)
		}
		e.stack = frames
	}
	sync.mutex_lock(&_pending_mutex)
	_ensure_init()
	append(&_pending, e)
	sync.mutex_unlock(&_pending_mutex)
}

// Move remote entries into `entries`. Call once per frame from the UI thread.
drain :: proc() {
	sync.mutex_lock(&_pending_mutex)
	defer sync.mutex_unlock(&_pending_mutex)
	for e in _pending {
		_make_room()
		_next_id += 1
		published := e
		published.id = _next_id
		append(&entries, published)
	}
	builtin.clear(&_pending)
}

_make_room :: proc() {
	for len(entries) >= MAX_ENTRIES {
		_entry_destroy(entries[0])
		ordered_remove(&entries, 0)
	}
}

_entry_destroy :: proc(e: Entry) {
	a := _log_alloc()
	delete(e.message, a)
	if e.owns_loc {
		delete(e.loc.file_path, a)
		delete(e.loc.procedure, a)
	}
	for s in e.stack {
		delete(s, a)
	}
	delete(e.stack, a)
}

// Call-stack capture via the EH-ABI unwinder + dladdr (both in libSystem).
// NOT libc backtrace(): that walks frame pointers, which Odin's codegen omits
// (it sees exactly one frame). NOT core:debug/trace either: its unix backend
// links libstdc++exp, which macOS clang doesn't ship. _Unwind_Backtrace uses
// the binary's unwind info, so it walks the full chain regardless.
// Gated on ODIN_DEBUG: only debug builds have symbols worth showing; the
// console's detail pane explains that in release builds.
when ODIN_OS == .Darwin {
	foreign import _libsystem "system:c"

	_Unwind_Context :: struct {}

	_Dl_Info :: struct {
		dli_fname: cstring,
		dli_fbase: rawptr,
		dli_sname: cstring,
		dli_saddr: rawptr,
	}

	@(default_calling_convention = "c")
	foreign _libsystem {
		_Unwind_Backtrace :: proc(fn: proc "c" (ctx: ^_Unwind_Context, user: rawptr) -> c.int, user: rawptr) -> c.int ---
		_Unwind_GetIP     :: proc(ctx: ^_Unwind_Context) -> uintptr ---
		dladdr            :: proc(addr: rawptr, info: ^_Dl_Info) -> c.int ---
	}

	_Unwind_Buf :: struct {
		pcs: [24]uintptr,
		n:   int,
	}

	_unwind_collect :: proc "c" (ctx: ^_Unwind_Context, user: rawptr) -> c.int {
		b := cast(^_Unwind_Buf)user
		if b.n >= len(b.pcs) do return 5 // _URC_END_OF_STACK
		b.pcs[b.n] = _Unwind_GetIP(ctx)
		b.n += 1
		return 0 // _URC_NO_REASON
	}
}

_capture_stack :: proc(a: runtime.Allocator) -> []string {
	if !ODIN_DEBUG do return nil
	when ODIN_OS == .Darwin {
		b: _Unwind_Buf
		_Unwind_Backtrace(_unwind_collect, &b)
		if b.n == 0 do return nil

		out := make([dynamic]string, 0, b.n, a)
		for i in 0 ..< b.n {
			info: _Dl_Info
			// -1: the captured pc is the return address, one past the call.
			if dladdr(rawptr(b.pcs[i] - 1), &info) == 0 || info.dli_sname == nil {
				append(&out, fmt.aprintf("0x%x", b.pcs[i], allocator = a))
				continue
			}
			name := string(info.dli_sname)
			// Skip this package's own frames (capture/append/level wrapper) so
			// the stack starts at the actual call site; stop at the C runtime
			// entry (everything below pkg::main is startup noise).
			if strings.contains(name, "mh_log") do continue
			if name == "main" || name == "start" do break
			append(&out, strings.clone(name, a))
		}
		return out[:]
	} else {
		return nil
	}
}

ordered_remove :: proc(s: ^[dynamic]Entry, index: int) {
	if index < 0 || index >= len(s) do return
	for i in index ..< len(s) - 1 {
		s[i] = s[i + 1]
	}
	pop(s)
}
