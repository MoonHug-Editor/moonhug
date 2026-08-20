package runconfig

// Support library for run configurations (docs/Plugins.md). A run config is an
// Odin PROGRAM, not a shell script: the editor compiles it with the host
// toolchain and runs it from the REPO ROOT, passing the live-scene snapshot
// path as an argument.
//
// Odin is already a hard dependency of this repo, so a config written in Odin
// runs anywhere the editor does — no sh on Windows, no per-OS script variants,
// no manifest schema to grow as the build story does. Cross-compiling, code
// signing, staging assets, launching a sidecar: all just code, using whatever
// this package and the rest of the repo already provide.
//
// This package is what keeps a config down to a few lines. It owns the shared
// odin flags, the platform executable suffix, output-directory creation, and
// stdio inheritance.
//
// Children inherit THIS process's stdout/stderr, which are the pipes the editor
// reads. So `odin build` diagnostics and the game's own tagged mh_log lines both
// reach the editor console with no extra wiring, exactly as they did when
// configs were scripts.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Appended to every `out` path, so one config source names one binary on every
// platform and nothing depends on whether the compiler adds a suffix itself.
EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

// A build of one package. `flags` is the escape hatch for anything this struct
// does not name — "-debug", "-o:speed", "-target:windows_amd64", "-define:X=Y".
// It is deliberately not a schema for those: a config is code, so a config that
// needs a matrix of targets writes a loop.
Config :: struct {
	package_path: string,   // repo-root relative, e.g. "moonhug/packages/app"
	out:          string,   // repo-root relative, e.g. "builds/app" (no suffix)
	flags:        []string,
}

// The repo root, found by walking up from the current directory looking for the
// `moonhug/` folder that every config path is relative to.
find_repo_root :: proc() -> (root: string, ok: bool) {
	dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return "", false
	for {
		marker, jerr := filepath.join({dir, "moonhug"}, context.temp_allocator)
		if jerr == nil && os.is_directory(marker) do return dir, true
		parent := filepath.dir(dir)
		if parent == dir do return "", false // hit the filesystem root
		dir = parent
	}
}

// Anchors the process at the repo root, so repo-root-relative paths mean the
// same thing however the config was launched — from the editor, from the repo
// root, or from any subdirectory. `build` does this for you.
chdir_repo_root :: proc() -> bool {
	root, ok := find_repo_root()
	if !ok {
		fmt.eprintf("run config: cannot find the repo root (no moonhug/ folder at or above the working directory)\n")
		return false
	}
	if err := os.set_working_directory(root); err != nil {
		fmt.eprintf("run config: cannot enter repo root %s: %v\n", root, err)
		return false
	}
	return true
}

// Builds `cfg`, then runs the result and exits with ITS exit code, so the editor
// reports what the game reported. Does not return.
build_and_run :: proc(cfg: Config, extra: ..string) {
	exe, ok := build(cfg)
	if !ok {
		fmt.eprintf("run config: build failed for %s\n", cfg.package_path)
		os.exit(1)
	}
	os.exit(run(exe, ..extra))
}

// Compiles `cfg` and returns the ABSOLUTE path to the binary. Creates the
// output directory first, the way `mkdir -p` did in the old scripts.
//
// Absolute matters: os.process_start resolves command[0] in the PARENT process,
// so a bare name goes through PATH but anything containing a '/' is opened
// relative to the CALLER's cwd rather than the child's working_dir. Returning
// an absolute path keeps `run` correct no matter where a config is invoked from.
build :: proc(cfg: Config) -> (exe: string, ok: bool) {
	// Anchor first: Config paths are repo-root relative, and the editor is not
	// the only caller — a config run from a terminal starts wherever you are.
	if !chdir_repo_root() do return "", false

	rel := strings.concatenate({cfg.out, EXE_SUFFIX}, context.temp_allocator)

	if dir := filepath.dir(cfg.out); dir != "" && dir != "." {
		os.make_directory_all(dir)
	}

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", cfg.package_path)
	// Every package in this repo needs these two, so no config repeats them.
	append(&cmd, "-ignore-unknown-attributes", "-collection:moonhug=moonhug")
	append(&cmd, ..cfg.flags)
	append(&cmd, fmt.tprintf("-out:%s", rel))

	if spawn(cmd[:]) != 0 do return "", false

	cwd, _ := os.get_working_directory(context.temp_allocator)
	abs, _ := filepath.join({cwd, rel}, context.temp_allocator)
	return abs, true
}

// Runs a built binary with THIS process's arguments appended after `extra` —
// that is the live-scene snapshot path when Play launched us. Returns its exit
// code. The old scripts spelled this `exec "$binary" "$@"`.
run :: proc(exe: string, extra: ..string) -> int {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, ..extra)
	if len(os.args) > 1 do append(&cmd, ..os.args[1:])
	return spawn(cmd[:])
}

// Runs any command to completion with this process's stdio and working
// directory, returning its exit code (negative when it could not start).
spawn :: proc(command: []string) -> int {
	p, err := os.process_start({
		command = command,
		stdout  = os.stdout,
		stderr  = os.stderr,
		stdin   = os.stdin,
	})
	if err != nil {
		fmt.eprintf("run config: cannot start %v: %v\n", command, err)
		return -1
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		fmt.eprintf("run config: wait failed for %v: %v\n", command, werr)
		return -1
	}
	return state.exit_code
}
