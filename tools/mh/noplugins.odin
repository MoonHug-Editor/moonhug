package mh

// `mh build --no-plugins`: the proof that the editor shell depends on no
// plugin. Every link in moonhug/packages is moved aside, the prebuild and the
// editor build run against the bare shell and libs, and the links come back
// whatever happened. The editor binary goes to a separate file, so the
// installed build is untouched. The last generator pass then regenerates the
// installed state, which is why the prebuild runs again at the end.
//
// A generator that writes into a plugin by path with that plugin absent would
// leave a real directory where the link was. Restore removes such a directory
// before putting the link back, and reports it, since it is a generator bug.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

ASIDE_DIR :: "builds/.packages_aside"
NOPLUGINS_BIN :: "builds/MoonHug-noplugins" + EXE

build_without_plugins :: proc() -> bool {
	r := _no_plugins(nil)
	return r.ok
}

// The stages of a no-plugins build, in order, and where it stopped.
@(private = "file")
No_Plugins_Stage :: enum {
	Aside,      // the plugin links moved aside
	Prebuild,   // the generators run on the bare shell
	Build,      // the editor compiled with no plugin
	Restore,    // the links back, no directory a generator made in their place
	Regenerate, // the generators run again on the installed state
}

@(private = "file")
No_Plugins_Result :: struct {
	ok:       bool,
	failed:   Maybe(No_Plugins_Stage), // the first stage that failed
	moved:    int,                     // links moved aside
	strays:   [dynamic]string,         // plugin paths a generator recreated as real directories
}

// The no-plugins build. `report`, when set, is called as each stage ends
// (mh check-noplugins prints a row per stage), otherwise mh prints its usual
// progress lines.
@(private = "file")
_no_plugins :: proc(report: proc(stage: No_Plugins_Stage, ok: bool, detail: string)) -> (r: No_Plugins_Result) {
	r.strays = make([dynamic]string, context.temp_allocator)
	done := proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), stage: No_Plugins_Stage, ok: bool, detail := "") -> bool {
		if !ok && r.failed == nil do r.failed = stage
		if report != nil do report(stage, ok, detail)
		return ok
	}
	links := _all_package_links()
	if len(links) == 0 {
		done(&r, report, .Aside, false, "no plugin links in moonhug/packages: is this the repository root?")
		return
	}
	os.make_directory_all(ASIDE_DIR)
	moved := make([dynamic]Link_Entry, context.temp_allocator)
	// The links come back whatever the build part did.
	built := _aside_and_build(&r, report, links, &moved, done)
	restored := _restore_links(moved[:], &r.strays, quiet = report != nil)
	restore_detail := len(r.strays) > 0 ? fmt.tprintf("a generator recreated %s as a real directory (removed)", strings.join(r.strays[:], ", ", context.temp_allocator)) : ""
	if done(&r, report, .Restore, restored && len(r.strays) == 0, restore_detail) {
		if report == nil do fmt.println("mh: links restored, regenerating the installed state")
		regen := prebuild()
		if !regen && report == nil do fmt.eprintln("mh: regenerating the installed state failed, run mh prebuild")
		done(&r, report, .Regenerate, regen, "")
	}
	r.ok = built && r.failed == nil
	return
}

// The links aside, the bare prebuild and the editor build, stopping at the
// first failure. `moved` lists what went aside, for the restore.
@(private = "file")
_aside_and_build :: proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), links: []Link_Entry, moved: ^[dynamic]Link_Entry, done: proc(r: ^No_Plugins_Result, report: proc(stage: No_Plugins_Stage, ok: bool, detail: string), stage: No_Plugins_Stage, ok: bool, detail := "") -> bool) -> bool {
	for e in links {
		if link_state(e) == .Missing do continue
		aside, _ := filepath.join({ASIDE_DIR, filepath.base(e.path)}, context.temp_allocator)
		if err := os.rename(e.path, aside); err != nil {
			return done(r, report, .Aside, false, fmt.tprintf("cannot move %s aside: %v", e.path, err))
		}
		append(moved, e)
	}
	r.moved = len(moved)
	done(r, report, .Aside, true, fmt.tprintf("%d plugin links", len(moved)))
	if report == nil do fmt.printfln("mh: %d plugin links aside, building the bare shell", len(moved))
	if !done(r, report, .Prebuild, prebuild()) do return false
	os.make_directory_all("builds")
	built := step("editor build (no plugins)", "odin", "build", "moonhug/editor", IGNORE_ATTRS, COLLECTION, VET, fmt.tprintf("-out:%s", NOPLUGINS_BIN))
	if !done(r, report, .Build, built, NOPLUGINS_BIN if built else "") do return false
	if report == nil do fmt.printfln("mh: the shell builds with no plugins, %s", NOPLUGINS_BIN)
	return true
}

// Every plugin link in moonhug/packages: the ones git tracks, and links that
// are on disk but not committed yet (a plugin just added). All of them go
// aside, or a new plugin would stay installed and need the absent engine.
@(private = "file")
_all_package_links :: proc() -> []Link_Entry {
	out := make([dynamic]Link_Entry, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for e in tracked_links() {
		append(&out, e)
		seen[e.path] = true
	}
	handle, oerr := os.open(PACKAGES_DIR)
	if oerr != nil do return out[:]
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return out[:]
	for e in entries {
		path := fmt.tprintf("%s/%s", PACKAGES_DIR, e.name)
		if path in seen do continue
		if _, lerr := os.read_link(path, context.temp_allocator); lerr != nil do continue
		append(&out, Link_Entry{path = path})
	}
	return out[:]
}

// Puts the links back. A directory a generator created where a link was is
// removed first and listed in `strays`. False when a link could not be put
// back.
@(private = "file")
_restore_links :: proc(moved: []Link_Entry, strays: ^[dynamic]string, quiet := false) -> (ok: bool) {
	ok = true
	for e in moved {
		if os.exists(e.path) {
			// Only a generator writing into an absent plugin produces this.
			if !quiet do fmt.eprintfln("mh: %s was recreated as a real directory during the no-plugins build (a generator wrote into an absent plugin), removing it", e.path)
			append(strays, e.path)
			os.remove_all(e.path)
		}
		aside, _ := filepath.join({ASIDE_DIR, filepath.base(e.path)}, context.temp_allocator)
		if err := os.rename(aside, e.path); err != nil {
			fmt.eprintfln("mh: cannot restore %s from %s: %v (mh setup repairs links from the index)", e.path, aside, err)
			ok = false
		}
	}
	os.remove(ASIDE_DIR)
	return
}

// `mh check-noplugins`: the no-plugins build as a pass or fail check. The
// tools' output goes to a log, the terminal gets one row per stage, and on a
// failure the first errors from the log and its path. The plugins are back
// and the installed state regenerated either way.
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
	fmt.println("No-plugins build check: the editor shell must build with every plugin set aside")
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
		fmt.printfln("PASS: the editor builds with no plugins (%.0f s, log %s)", secs, NOPLUGINS_LOG)
		return 0
	}
	failed := r.failed.? or_else .Aside
	fmt.printfln("FAIL: %s (%.0f s). Its output, from %s:", _STAGE_NAMES[failed], secs, NOPLUGINS_LOG)
	for line in _stage_output(NOPLUGINS_LOG, _fail_segment, 20) do fmt.printfln("    %s", line)
	return 1
}

@(private = "file")
_STAGE_NAMES := [No_Plugins_Stage]string{
	.Aside      = "move the plugin links aside",
	.Prebuild   = "prebuild on the bare shell",
	.Build      = "build the editor",
	.Restore    = "restore the plugin links",
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
