#+build darwin, linux
package crash_journal

// Crash journal: a signal-safe last-words file for crashes that can't be
// reproduced on demand (docs/CrashJournal.md).
//
// On SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT — or a panic/assert — the handler
// writes logs/crash_<pid>.log with the reason, faulting address, breadcrumb
// (what the editor was doing) and a symbolized stack, then re-raises the
// signal so the crash still surfaces normally.
//
// Everything on the crash path is async-signal-safe:
//   - fixed static storage, no allocation (a corrupt heap must not matter)
//   - an alternate signal stack, so a stack-overflow SIGSEGV still handles
//   - raw write(2) and libc backtrace_symbols_fd, never fmt/os buffering
//   - a reentrancy guard: a fault INSIDE the handler restores SIG_DFL and
//     re-raises instead of looping
//
// Breadcrumbs are optional context. A stack says where it died. A breadcrumb
// says what it was doing — breadcrumb("thumbnail: <path>") turns "it crashed
// while browsing" into a reproducible report. Nothing depends on them.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:os"
import posix "core:sys/posix"

CRASH_MAX_FRAMES :: 64
CRASH_BREADCRUMB_MAX :: 256
CRASH_DIR :: "logs"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
	// Writes symbolized frames straight to an fd — the malloc-free counterpart
	// of backtrace_symbols, and the reason we can symbolize inside a handler.
	backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: c.int, fd: c.int) ---
}

// Static, process-owned: the handler must not touch an allocator, a context,
// or any engine state that could be mid-mutation when the fault hit.
@(private = "file") _crash: struct {
	installed:        bool,
	in_handler:       bool,
	alt_stack:        [posix.SIGSTKSZ]byte,
	frames:           [CRASH_MAX_FRAMES]rawptr,
	breadcrumb:       [CRASH_BREADCRUMB_MAX]byte,
	breadcrumb_len:   int,
	path:             [256]byte, // logs/crash_<pid>.log, built once at init
	path_len:         int,
	version:          [64]byte, // handed to init, written in the header
	version_len:      int,
}

// Installs signal handlers. Safe to call twice — the second call is a no-op.
//
// Panics and failed asserts do NOT route here automatically:
// assertion_failure_proc lives on the CONTEXT, so it must be installed by the
// caller whose scope should carry it (main). Assign it right after this:
//
//	engine.init()
//	context.assertion_failure_proc = engine.assertion_failure
init :: proc(version := "") {
	// The version updates even on a repeat call — only the handler install
	// is once-only.
	v := version
	for len(v) > 0 && (v[len(v) - 1] == '\n' || v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
		v = v[:len(v) - 1]
	}
	n := min(len(v), len(_crash.version))
	copy(_crash.version[:n], v[:n])
	_crash.version_len = n

	if _crash.installed do return
	_crash.installed = true

	os.make_directory(CRASH_DIR)
	_crash_build_path()

	// A stack-overflow SIGSEGV leaves no room to run the handler on the
	// faulting stack, so give it its own.
	alt := posix.stack_t{
		ss_sp    = raw_data(_crash.alt_stack[:]),
		ss_size  = c.size_t(len(_crash.alt_stack)),
		ss_flags = {},
	}
	_ = posix.sigaltstack(&alt, nil)

	act: posix.sigaction_t
	act.sa_sigaction = _crash_signal_handler
	act.sa_flags = {.SIGINFO, .ONSTACK}
	posix.sigemptyset(&act.sa_mask)
	for sig in ([?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, SIGTRAP}) {
		posix.sigaction(sig, &act, nil)
	}
}

// Odin's assert/panic ends in runtime.trap(), which raises SIGTRAP. Catching
// it journals asserts from ANY context — assertion_failure below only covers
// contexts it was installed on. Not in posix.Signal's members, value 5
// everywhere the editor runs. Debuggers intercept breakpoint traps before
// delivery, so this never fires under lldb.
SIGTRAP :: posix.Signal(5)

// Records what the process is currently doing. Overwrites the previous one —
// this is the "last known activity", not a trail. Cheap enough to call per
// operation (a copy into fixed storage, no allocation). Safe from any thread
// in the sense that a torn breadcrumb is still better than none.
breadcrumb :: proc(text: string) {
	n := min(len(text), CRASH_BREADCRUMB_MAX)
	copy(_crash.breadcrumb[:n], text[:n])
	_crash.breadcrumb_len = n
}

breadcrumb_clear :: proc() {
	_crash.breadcrumb_len = 0
}

// _crash_fault_pc reads the faulting PC/LR out of a signal ucontext. Its
// layout is per-OS, so it lives in crash_journal_darwin.odin /
// crash_journal_linux.odin — a `when` guards code but not imports, and the
// darwin one needs core:sys/darwin, which a linux build must not pull in.

// --- Handler ---------------------------------------------------------------

@(private = "file")
_crash_signal_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ctx: rawptr) {
	// Faulting again inside the handler means the journal itself is unsafe
	// (corrupt state, bad fd). Give up and let the OS handle it normally.
	if _crash.in_handler {
		_crash_restore_default(sig)
		posix.raise(sig)
		return
	}
	_crash.in_handler = true

	reason: string
	#partial switch sig {
	case .SIGSEGV: reason = "SIGSEGV (invalid memory reference)"
	case .SIGBUS:  reason = "SIGBUS (bad memory access)"
	case .SIGILL:  reason = "SIGILL (illegal instruction)"
	case .SIGFPE:  reason = "SIGFPE (arithmetic error)"
	case .SIGABRT: reason = "SIGABRT (abort)"
	case SIGTRAP:  reason = "SIGTRAP (failed assert or panic — message is on stderr)"
	case:          reason = "unknown signal"
	}
	addr: rawptr = info != nil ? info.si_addr : nil

	fault_pc, fault_lr := _crash_fault_pc(ctx)
	_crash_write(reason, addr, fault_pc, fault_lr)

	// Re-raise so the process still dies the way it would have: debuggers
	// still break, exit codes still report, nothing is swallowed.
	_crash_restore_default(sig)
	posix.raise(sig)
}

// Install as context.assertion_failure_proc to journal panics and asserts.
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	if !_crash.in_handler {
		_crash.in_handler = true
		_crash_write_assert(prefix, message, loc)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

@(private = "file")
_crash_restore_default :: proc "c" (sig: posix.Signal) {
	act: posix.sigaction_t
	act.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &act, nil)
}

// --- Writing ---------------------------------------------------------------
// Raw open/write only: fmt allocates and os.write buffers, neither is legal
// after a fault.

@(private = "file")
_crash_write :: proc "contextless" (reason: string, addr: rawptr, fault_pc: rawptr = nil, fault_lr: rawptr = nil) {
	fd := _crash_open()
	if fd < 0 do return
	defer posix.close(fd)

	_crash_write_header(fd)
	_w(fd, "reason: ")
	_w(fd, reason)
	_w(fd, "\n")
	if addr != nil {
		_w(fd, "fault address: 0x")
		_w_hex(fd, u64(uintptr(addr)))
		_w(fd, "\n")
	}
	_crash_write_breadcrumb(fd)
	_crash_write_stack(fd, fault_pc, fault_lr)
}

@(private = "file")
_crash_write_assert :: proc(prefix, message: string, loc: runtime.Source_Code_Location) {
	fd := _crash_open()
	if fd < 0 do return
	defer posix.close(fd)

	_crash_write_header(fd)
	_w(fd, "reason: ")
	_w(fd, prefix)
	if message != "" {
		_w(fd, ": ")
		_w(fd, message)
	}
	_w(fd, "\n")
	_w(fd, "at: ")
	_w(fd, loc.file_path)
	_w(fd, ":")
	_w_int(fd, int(loc.line))
	if loc.procedure != "" {
		_w(fd, " in ")
		_w(fd, loc.procedure)
	}
	_w(fd, "\n")
	_crash_write_breadcrumb(fd)
	_crash_write_stack(fd, nil, nil)
}

// Title, editor version, crash time (UTC). clock_gettime is
// async-signal-safe, the date math is our own — no localtime, no fmt.
@(private = "file")
_crash_write_header :: proc "contextless" (fd: posix.FD) {
	_w(fd, "=== MoonHug crash ===\n")
	if _crash.version_len > 0 {
		_w(fd, "version: ")
		_w(fd, string(_crash.version[:_crash.version_len]))
		_w(fd, "\n")
	}
	ts: posix.timespec
	if posix.clock_gettime(.REALTIME, &ts) == .OK {
		_w(fd, "time: ")
		_w_utc(fd, i64(ts.tv_sec))
		_w(fd, " UTC\n")
	}
}

// YYYY-MM-DD HH:MM:SS from unix seconds (Hinnant's civil_from_days).
@(private = "file")
_w_utc :: proc "contextless" (fd: posix.FD, epoch: i64) {
	days := epoch / 86400
	secs := epoch % 86400
	if secs < 0 {
		secs += 86400
		days -= 1
	}
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	if m <= 2 do y += 1

	_w_int(fd, int(y))
	_w(fd, "-")
	_w_2d(fd, int(m))
	_w(fd, "-")
	_w_2d(fd, int(d))
	_w(fd, " ")
	_w_2d(fd, int(secs / 3600))
	_w(fd, ":")
	_w_2d(fd, int(secs / 60 % 60))
	_w(fd, ":")
	_w_2d(fd, int(secs % 60))
}

@(private = "file")
_w_2d :: proc "contextless" (fd: posix.FD, v: int) {
	buf := [2]byte{byte('0' + v / 10 % 10), byte('0' + v % 10)}
	_ = posix.write(fd, raw_data(buf[:]), 2)
}

@(private = "file")
_crash_write_breadcrumb :: proc "contextless" (fd: posix.FD) {
	if _crash.breadcrumb_len <= 0 do return
	_w(fd, "doing: ")
	_w(fd, string(_crash.breadcrumb[:_crash.breadcrumb_len]))
	_w(fd, "\n")
}

@(private = "file")
_crash_write_stack :: proc "contextless" (fd: posix.FD, fault_pc: rawptr, fault_lr: rawptr) {
	_w(fd, "stack:\n")
	// Frames 0..1 = the faulting PC and its return address, recovered from the
	// trap frame. libc's walk resumes at the handler and cannot see them.
	n := 0
	if fault_pc != nil {
		_crash.frames[n] = fault_pc
		n += 1
	}
	if fault_lr != nil && fault_lr != fault_pc {
		_crash.frames[n] = fault_lr
		n += 1
	}
	// The libc walk begins inside this handler, so drop its own frames
	// (_crash_write_stack, _crash_write, the signal handler) — they are noise
	// and, on a broken chain, duplicates of the PC we already recovered.
	scratch: [CRASH_MAX_FRAMES]rawptr
	captured := int(backtrace(raw_data(scratch[:]), CRASH_MAX_FRAMES))
	HANDLER_FRAMES :: 3
	first := min(HANDLER_FRAMES, captured)
	for i in first ..< captured {
		if n >= CRASH_MAX_FRAMES do break
		f := scratch[i]
		if f == fault_pc || f == fault_lr do continue // already listed
		_crash.frames[n] = f
		n += 1
	}
	if n <= 0 {
		// Asserts reach here through a no-return proc, which establishes no
		// frame pointer for libc to walk — the `at:` line above is the
		// authoritative location in that case.
		_w(fd, "  <unavailable; see 'at:' above>\n")
		return
	}
	backtrace_symbols_fd(raw_data(_crash.frames[:]), c.int(n), c.int(fd))
}

// logs/crash_<pid>.log, built at init so the handler never formats a path.
@(private = "file")
_crash_build_path :: proc() {
	prefix := CRASH_DIR + "/crash_"
	n := copy(_crash.path[:], prefix)
	pid := os.get_pid()
	digits: [20]byte
	d := len(digits)
	v := pid if pid > 0 else 0
	if v == 0 {
		d -= 1
		digits[d] = '0'
	}
	for v > 0 {
		d -= 1
		digits[d] = byte('0' + v % 10)
		v /= 10
	}
	n += copy(_crash.path[n:], digits[d:])
	n += copy(_crash.path[n:], ".log")
	_crash.path[n] = 0
	_crash.path_len = n
}

@(private = "file")
_crash_open :: proc "contextless" () -> posix.FD {
	if _crash.path_len <= 0 do return -1
	return posix.open(cstring(raw_data(_crash.path[:])),
		{.WRONLY, .CREAT, .TRUNC}, {.IWUSR, .IRUSR, .IRGRP, .IROTH})
}

@(private = "file")
_w :: proc "contextless" (fd: posix.FD, s: string) {
	if len(s) == 0 do return
	_ = posix.write(fd, raw_data(s), c.size_t(len(s)))
}

@(private = "file")
_w_hex :: proc "contextless" (fd: posix.FD, v: u64) {
	digits := "0123456789abcdef"
	buf: [16]byte
	i := len(buf)
	v := v
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = digits[v & 0xF]
		v >>= 4
	}
	_ = posix.write(fd, raw_data(buf[i:]), c.size_t(len(buf) - i))
}

@(private = "file")
_w_int :: proc "contextless" (fd: posix.FD, v: int) {
	buf: [20]byte
	i := len(buf)
	v := v
	if v == 0 {
		i -= 1
		buf[i] = '0'
	}
	for v > 0 {
		i -= 1
		buf[i] = byte('0' + v % 10)
		v /= 10
	}
	_ = posix.write(fd, raw_data(buf[i:]), c.size_t(len(buf) - i))
}

// Test hook: writes a journal entry as if a signal had fired, without
// crashing. Used by the test suite and `crash_journal_selftest`.
write_test_entry :: proc(reason: string) {
	was := _crash.in_handler
	_crash.in_handler = true
	defer _crash.in_handler = was
	_crash_write(reason, nil, nil, nil)
}

path :: proc() -> string {
	if _crash.path_len <= 0 do return ""
	return string(_crash.path[:_crash.path_len])
}

// Deliberate fault — proves the handler works end to end. Only reachable
// from --crash-test.
//
// A plain null-pointer write is NOT usable here: that is undefined behaviour,
// and optimized builds delete it outright (the self-test then "passes" while
// testing nothing). Writing through a volatile-loaded address the compiler
// cannot reason about produces a real SIGSEGV in every build mode.
@(optimization_mode = "none")
test_crash :: proc() {
	breadcrumb("test_crash (deliberate)")
	addr: uintptr = 0x8 // never mapped
	p := (^int)(intrinsics.volatile_load(&addr))
	intrinsics.volatile_store(p, 1)
}
