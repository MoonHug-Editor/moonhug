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
import "moonhug:engine/catalog"

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

// The editor's toolbar modifiers arrive as flags, honored inside the rc procs
// so config files stay straight-line scripts: --build-only (Alt) builds and
// stages data but skips every run step, --run-only (Shift) runs what the last
// build produced, skipping the compile and the data staging.
build_only :: proc() -> bool {
	for arg in os.args[1:] {
		if arg == "--build-only" do return true
	}
	return false
}

run_only :: proc() -> bool {
	for arg in os.args[1:] {
		if arg == "--run-only" do return true
	}
	return false
}

// The scene the invoker passed (the editor's Build button forwards its
// live-scene snapshot). "" when launched bare or from the Play button — the
// config's own pinned scene then applies.
scene_arg :: proc() -> string {
	for arg in os.args[1:] {
		if !strings.has_prefix(arg, "--") do return arg
	}
	return ""
}

// Builds `cfg`, then runs the result and exits with ITS exit code, so the editor
// reports what the game reported. Does not return.
build_and_run :: proc(cfg: Config, extra: ..string) {
	exe, ok := build(cfg)
	if !ok {
		fmt.eprintf("run config: build failed for %s\n", cfg.package_path)
		os.exit(1)
	}
	if build_only() do os.exit(0)
	os.exit(run(exe, ..extra))
}

// Stage the build's data dir: <out>_data beside the binary (Unity's
// Game + Game_Data layout), copied from the editor-maintained
// library/catalog.json with a relocatable catalog written beside it. `scene`
// is the config's pinned boot scene (moonhug-relative asset path) — the
// staged data is ALWAYS the config's own build, so bare launches reproduce
// it exactly. The editor's scene only ever affects the run (scene_arg,
// forwarded by the run procs), never the build.
export_data :: proc(out: string, scene := "") -> bool {
	if !chdir_repo_root() do return false
	data_dir := fmt.tprintf("%s_data", out)
	// Run-only (Shift): keep the last build's staged data.
	if run_only() {
		if !os.exists(fmt.tprintf("%s/catalog.json", data_dir)) {
			fmt.eprintf("run config: no staged data at %s — build first (run without Shift)\n", data_dir)
			return false
		}
		return true
	}
	if !catalog.export_from("moonhug/library/catalog.json", data_dir, scene, root = "moonhug") {
		fmt.eprintf("run config: data export failed for %s (is the editor's catalog current?)\n", out)
		return false
	}
	return true
}

// A config's error exit with a uniform message. Does not return.
exit_build_failed :: proc(what: string) {
	fmt.eprintf("run config: build failed for %s\n", what)
	os.exit(1)
}

// Runs a built binary under the catalog pipeline: --catalog against its own data dir. An invoker
// scene (the editor Build button's live-scene snapshot) forwards to the game
// and overrides the exported boot scene for THIS run only — assets still
// resolve through the catalog. Honors --build-only. Does not return.
run_build :: proc(out: string) {
	if build_only() do os.exit(0)
	if !chdir_repo_root() do os.exit(1)
	rel := strings.concatenate({out, EXE_SUFFIX}, context.temp_allocator)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	abs, _ := filepath.join({cwd, rel}, context.temp_allocator)
	// The game normalizes its own cwd to moonhug/, so the catalog path is
	// spelled from there.
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, abs, fmt.tprintf("--catalog=../%s_data/catalog.json", out))
	if scene := scene_arg(); scene != "" do append(&cmd, scene)
	os.exit(spawn(cmd[:]))
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

	// Run-only (Shift): skip the compile, hand back the last build's binary.
	if run_only() {
		if !os.exists(rel) {
			fmt.eprintf("run config: no binary at %s — build first (run without Shift)\n", rel)
			return "", false
		}
		cwd, _ := os.get_working_directory(context.temp_allocator)
		abs, _ := filepath.join({cwd, rel}, context.temp_allocator)
		return abs, true
	}

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
