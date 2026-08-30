package mh

// Running other programs, finding things on disk. The pieces every command
// needs and neither Odin's core nor a shell gives us portably.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Appended to every binary this tool produces, so one spelling names one file
// on every platform. Windows `odin build` also refuses an extension-less -out.
EXE :: ".exe" when ODIN_OS == .Windows else ""

// Flags every package in this repo needs. One definition — commands never
// repeat them.
COLLECTION :: "-collection:moonhug=moonhug"
IGNORE_ATTRS :: "-ignore-unknown-attributes"

// Unused imports and variables are compile errors here. They accumulate
// silently otherwise — a moved call leaves its import behind and nothing ever
// says so.
//
// Only this check, not full -vet: -vet-shadowing fires on `if x, ok := v.(T)`
// chains, where each branch reopens `ok` in its own scope, which is the
// idiomatic spelling and appears throughout the inspector and scene code.
// -vet-cast is also out — it reports the transmute in view_animation.odin as
// unneeded, but Asset_GUID is a distinct [16]u8 and Odin has no cast for that.
VET :: "-vet-unused"

// run executes a command to completion with this process's stdio, so compiler
// diagnostics and program output reach the terminal unbuffered and in order.
// Returns its exit code, or -1 when it could not start.
run :: proc(command: ..string) -> int {
	p, err := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s: %v", command[0], err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
		return -1
	}
	return state.exit_code
}

// run_in is `run` with a working directory, for the vendored library builds
// that only work from their own source folder.
run_in :: proc(dir: string, command: ..string) -> int {
	p, err := os.process_start({command = command, working_dir = dir, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin})
	if err != nil {
		fmt.eprintfln("mh: cannot start %s in %s: %v", command[0], dir, err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintfln("mh: wait failed for %s: %v", command[0], werr)
		return -1
	}
	return state.exit_code
}

// step runs a command and reports failure with the stage that failed, so a
// broken chain names its own broken link.
step :: proc(what: string, command: ..string) -> bool {
	if code := run(..command); code != 0 {
		fmt.eprintfln("mh: %s failed (exit %d)", what, code)
		return false
	}
	return true
}

// have reports whether an executable is on PATH. Replaces the shell's
// `command -v`, which has no Windows equivalent — this is why the optional
// shader step could only ever be guarded from sh.
have :: proc(tool: string) -> bool {
	path, found := os.lookup_env("PATH", context.temp_allocator)
	if !found do return false
	sep := ";" when ODIN_OS == .Windows else ":"
	name := strings.concatenate({tool, EXE}, context.temp_allocator)
	for dir in strings.split(path, sep, context.temp_allocator) {
		if dir == "" do continue
		p, err := filepath.join({dir, name}, context.temp_allocator)
		if err == nil && os.exists(p) do return true
	}
	return false
}

// newer_than reports whether `out` exists and was written after `src`. False
// when either cannot be read, so an unreadable file rebuilds rather than
// silently keeping stale output.
newer_than :: proc(out, src: string) -> bool {
	out_t, oerr := os.modification_time_by_path(out)
	if oerr != nil do return false
	src_t, serr := os.modification_time_by_path(src)
	if serr != nil do return false
	return time.diff(src_t, out_t) > 0
}

// The Odin installation's vendor/ tree, for the libraries setup builds.
// ODIN_ROOT is filled in by the compiler, so this needs no `odin root` call.
odin_vendor :: proc(rest: ..string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, ODIN_ROOT, "vendor")
	append(&parts, ..rest)
	joined, _ := filepath.join(parts[:], context.temp_allocator)
	return joined
}

// The repo root, found by walking up for the moonhug/ folder every path here
// is relative to. Commands run from the root whatever directory invoked them.
repo_root :: proc() -> (root: string, ok: bool) {
	dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return "", false
	for {
		marker, jerr := filepath.join({dir, "moonhug"}, context.temp_allocator)
		if jerr == nil && os.is_dir(marker) do return dir, true
		parent: string
		{
			// filepath.dir has no allocator parameter.
			context.allocator = context.temp_allocator
			parent = filepath.dir(dir)
		}
		if parent == dir do return "", false // filesystem root
		dir = parent
	}
}

chdir_repo_root :: proc() -> bool {
	root, ok := repo_root()
	if !ok {
		fmt.eprintln("mh: cannot find the repo root (no moonhug/ folder at or above the working directory)")
		return false
	}
	if err := os.set_working_directory(root); err != nil {
		fmt.eprintfln("mh: cannot enter repo root %s: %v", root, err)
		return false
	}
	return true
}
