package mh

// `mh build --no-plugins` and `mh check-noplugins`: the proof that the editor
// shell depends on no plugin. The prebuild runs with `--no-packages`, so the
// generators see moonhug/packages as empty whatever it holds (links, folders,
// submodules) and write nothing under it; the editor then compiles from that
// generated state into a separate binary, the installed build untouched. The
// check also runs that binary for a few seconds in a scratch project. The
// last stage runs the prebuild again, which regenerates the installed state.
//
// Nothing on disk moves: the generated files of the shell and the libs are
// the only files that change, and the last stage puts them back.

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

NOPLUGINS_BIN :: "builds/MoonHug-noplugins" + EXE

build_without_plugins :: proc() -> bool {
	r := _no_plugins(nil)
	return r.ok
}

// The stages of a no-plugins build, in order, and where it stopped.
@(private = "file")
No_Plugins_Stage :: enum {
	Prebuild,   // the generators run on the bare shell
	Build,      // the editor compiled with no plugin
	Run,        // the editor launched for a few seconds and closed
	Regenerate, // the generators run again on the installed state
}

@(private = "file")
No_Plugins_Result :: struct {
	ok:     bool,
	failed: Maybe(No_Plugins_Stage), // the first stage that failed
}

// The no-plugins build. `report`, when set, is called as each stage ends
// (mh check-noplugins prints a row per stage), otherwise mh prints its usual
// progress lines.
@(private = "file")
_no_plugins :: proc(report: proc(stage: No_Plugins_Stage, ok: bool, detail: string)) -> (r: No_Plugins_Result) {
	done := proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), stage: No_Plugins_Stage, ok: bool, detail := "") -> bool {
		if !ok && r.failed == nil do r.failed = stage
		if report != nil do report(stage, ok, detail)
		return ok
	}
	built := _build_bare(&r, report, done)
	// The installed state comes back whatever the build part did.
	if report == nil do fmt.println("mh: regenerating the installed state")
	regen := prebuild()
	if !regen && report == nil do fmt.eprintln("mh: regenerating the installed state failed, run mh prebuild")
	done(&r, report, .Regenerate, regen, "")
	r.ok = built && r.failed == nil
	return
}

// The bare prebuild, the editor build and the run, stopping at the first
// failure.
@(private = "file")
_build_bare :: proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), done: proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), stage: No_Plugins_Stage, ok: bool, detail := "") -> bool) -> bool {
	if report == nil do fmt.println("mh: building the bare shell, the packages folder ignored")
	if !done(r, report, .Prebuild, prebuild(no_packages = true)) do return false
	os.make_directory_all("builds")
	built := step("editor build (no plugins)", "odin", "build", "moonhug/editor", IGNORE_ATTRS, COLLECTION, VET, fmt.tprintf("-out:%s", NOPLUGINS_BIN))
	if !done(r, report, .Build, built, NOPLUGINS_BIN if built else "") do return false
	if report == nil do fmt.printfln("mh: the shell builds with no plugins, %s", NOPLUGINS_BIN)
	ran, detail := _smoke_run()
	if !done(r, report, .Run, ran, detail) do return false
	if report == nil do fmt.printfln("mh: the shell runs with no plugins (%s)", detail)
	return true
}

// The scratch project the no-plugins editor runs in.
SMOKE_PROJECT_DIR :: "builds/noplugins-project"

// How long the no-plugins editor runs in the smoke stage. Its first frames
// are what fail when the shell leans on something only a plugin installs,
// and a build alone cannot tell.
SMOKE_SECONDS :: 5

// The MCP bridge's port (editor/mcp): an editor already running holds it,
// and two editors must not share one project library, so the smoke is
// skipped while it is in use.
EDITOR_MCP_PORT :: 6600

// Launches the no-plugins editor, lets it run SMOKE_SECONDS, then terminates
// it. Its window opens and closes on its own. Fails when it exits by itself
// before the time is up, with the exit code (a crash reports its signal).
@(private = "file")
_smoke_run :: proc() -> (ok: bool, detail: string) {
	if sock, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = EDITOR_MCP_PORT}); derr == nil {
		net.close(sock)
		return true, "skipped, an editor is already running (its MCP port answers)"
	}
	out := run_log if run_log != nil else os.stdout
	errs := run_log if run_log != nil else os.stderr
	// It runs in a scratch project of its own, named outright with
	// `--project=` so the editor's startup walk cannot climb into the user's
	// project (assets/project_root.odin). Its layout, settings and artifact
	// library land there. In the user's project it would sweep the artifacts
	// of the plugins it cannot see as stale, and overwrite the window layout.
	// Absolute paths from the working directory: filepath.abs goes through
	// the filesystem and returns nothing for a directory not created yet.
	cwd, cerr := os.get_working_directory(context.temp_allocator)
	if cerr != nil do return false, fmt.tprintf("cannot read the working directory: %v", cerr)
	project, _ := filepath.join({cwd, SMOKE_PROJECT_DIR}, context.temp_allocator)
	bin, _ := filepath.join({cwd, NOPLUGINS_BIN}, context.temp_allocator)
	os.make_directory_all(fmt.tprintf("%s/assets", project))
	os.make_directory_all(fmt.tprintf("%s/ProjectSettings", project))
	p, err := os.process_start({command = {bin, fmt.tprintf("--project=%s", project)}, working_dir = project, stdout = out, stderr = errs})
	if err != nil do return false, fmt.tprintf("cannot start %s: %v", NOPLUGINS_BIN, err)
	state, werr := os.process_wait(p, SMOKE_SECONDS * time.Second)
	if werr == nil && state.exited {
		return false, fmt.tprintf("exited on its own within %d s, code %d", SMOKE_SECONDS, state.exit_code)
	}
	if werr != nil && werr != .Timeout {
		_ = os.process_kill(p)
		return false, fmt.tprintf("wait failed: %v", werr)
	}
	_ = os.process_terminate(p)
	state, werr = os.process_wait(p, 10 * time.Second)
	if werr != nil || !state.exited {
		_ = os.process_kill(p)
		return false, "did not stop within 10 s of terminate"
	}
	return true, fmt.tprintf("ran %d s, closed on terminate", SMOKE_SECONDS)
}

// `mh check-noplugins`: the no-plugins build and run as a pass or fail check. The
// tools' output goes to a log, the terminal gets one row per stage, and on a
// failure the first errors from the log and its path. The installed state is
// regenerated either way.
NOPLUGINS_LOG :: "builds/noplugins-check.log"

cmd_check_noplugins :: proc(args: []string) -> int {
	os.make_directory_all("builds")
	log, lerr := os.create(NOPLUGINS_LOG)
	if lerr != nil {
		fmt.eprintfln("mh: cannot create %s: %v", NOPLUGINS_LOG, lerr)
		return 1
	}
	run_log = log
	_last_mark = 0
	_fail_segment = {}
	start := time.now()
	fmt.println("No-plugins build check: the editor shell must build and run with the packages folder ignored")
	r := _no_plugins(proc(stage: No_Plugins_Stage, ok: bool, detail: string) {
		// The log from the end of the stage before to here is this stage's.
		size: i64
		if fi, serr := os.stat(NOPLUGINS_LOG, context.temp_allocator); serr == nil do size = fi.size
		if !ok && _fail_segment == {} do _fail_segment = {_last_mark, size}
		_last_mark = size
		mark := "ok" if ok else "FAILED"
		dots := strings.repeat(".", max(2, 36 - len(_STAGE_NAMES[stage])), context.temp_allocator)
		if detail != "" {
			fmt.printfln("  %s %s %s  (%s)", _STAGE_NAMES[stage], dots, mark, detail)
		} else {
			fmt.printfln("  %s %s %s", _STAGE_NAMES[stage], dots, mark)
		}
	})
	run_log = nil
	os.close(log)
	secs := time.duration_seconds(time.since(start))
	if r.ok {
		fmt.printfln("PASS: the editor builds and runs with no plugins (%.0f s, log %s)", secs, NOPLUGINS_LOG)
		return 0
	}
	failed := r.failed.? or_else .Prebuild
	fmt.printfln("FAIL: %s (%.0f s). Its output, from %s:", _STAGE_NAMES[failed], secs, NOPLUGINS_LOG)
	for line in _stage_output(NOPLUGINS_LOG, _fail_segment, 20) do fmt.printfln("    %s", line)
	return 1
}

@(private = "file")
_STAGE_NAMES := [No_Plugins_Stage]string{
	.Prebuild   = "prebuild with the packages folder ignored",
	.Build      = "build the editor",
	.Run        = "run the editor",
	.Regenerate = "regenerate the installed state",
}

// Where each stage's output starts in the log, and the failed stage's span.
@(private = "file") _last_mark: i64
@(private = "file") _fail_segment: [2]i64

// The first `n` lines of the log between the two offsets, without the
// generators' timing and warning lines.
@(private = "file")
_stage_output :: proc(path: string, seg: [2]i64, n: int) -> []string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}
	lo, hi := clamp(int(seg[0]), 0, len(data)), clamp(int(seg[1]), 0, len(data))
	if hi <= lo do hi = len(data)
	out := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(string(data[lo:hi]), context.temp_allocator) {
		if strings.has_prefix(l, "timing:") || strings.contains(l, ": warning:") || strings.trim_space(l) == "" do continue
		append(&out, l)
		if len(out) == n do break
	}
	return out[:]
}
