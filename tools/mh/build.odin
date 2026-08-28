package mh

// Building and running the editor, the game, the tests and the MCP shim.

import "core:fmt"
import "core:os"

EDITOR_BIN :: "builds/MoonHug" + EXE
MCP_BIN :: "builds/mcp_shim" + EXE

// Code generation, always before a build. Two steps: prune imports of removed
// package generators first — a stale one fails the prebuild compile before
// prebuild can heal the file itself — then run the generators.
prebuild :: proc() -> bool {
	if !step("prune", "odin", "run", "moonhug/prebuild/prune_package_gens") do return false
	if !step("prebuild", "odin", "run", "moonhug/prebuild", COLLECTION) do return false
	return true
}

// Compiled shader blobs are committed, so this toolchain is optional and the
// step is skipped when it is absent (only authoring shaders needs it).
// Unchanged shaders are skipped too — see shaders_compile.
shaders_if_available :: proc() -> bool {
	if !have("glslc") || !have("spirv-cross") do return true
	return shaders_compile()
}

// build_editor: generate, shaders, compile. `out` is named MoonHug so macOS
// shows that in the App Switcher and menu bar instead of the package name.
build_editor :: proc(debug: bool) -> bool {
	if !prebuild() do return false
	if !shaders_if_available() do return false
	os.make_directory_all("builds")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", "moonhug/editor", IGNORE_ATTRS, COLLECTION)
	if debug do append(&cmd, "-debug")
	append(&cmd, fmt.tprintf("-out:%s", EDITOR_BIN))
	return step("editor build", ..cmd[:])
}

// Build then run as a CHILD process, not `odin run`: `odin run` keeps the
// ~1GB compiler resident for the whole life of the editor just to wait on it.
cmd_run :: proc(args: []string) -> int {
	if !build_editor(false) do return 1
	return run(EDITOR_BIN)
}

cmd_debug :: proc(args: []string) -> int {
	if !build_editor(true) do return 1
	return run(EDITOR_BIN)
}

cmd_build :: proc(args: []string) -> int {
	if !build_editor(has_flag(args, "--debug")) do return 1
	fmt.printfln("mh: built %s", EDITOR_BIN)
	return 0
}

cmd_prebuild :: proc(args: []string) -> int {
	return 0 if prebuild() else 1
}

// The game, through its run config (docs/Plugins.md) — the same path the
// editor's Play button takes, so a terminal run and a Play run agree.
cmd_app :: proc(args: []string) -> int {
	if !prebuild() do return 1
	config := "run_debug.odin" if has_flag(args, "--debug") else "run.odin"
	return run("odin", "run", fmt.tprintf("moonhug/packages/app/run_configs/%s", config), "-file", COLLECTION)
}

// -define:ODIN_TEST_THREADS=1 keeps tests serial: they share the asset db and
// fixture files on disk.
cmd_test :: proc(args: []string) -> int {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "test", "moonhug/tests", "-all-packages", IGNORE_ATTRS, COLLECTION, "-define:ODIN_TEST_THREADS=1")
	if name := flag_value(args, "--name"); name != "" {
		append(&cmd, fmt.tprintf("-define:ODIN_TEST_NAMES=%s", name))
	}
	return run(..cmd[:])
}

// The MCP stdio server the client spawns (.mcp.json, docs/McpBridge.md).
// Build diagnostics go to stderr so stdout stays a clean JSON-RPC stream.
cmd_mcp :: proc(args: []string) -> int {
	os.make_directory_all("builds")
	if code := run("odin", "build", "moonhug/mcp_shim", COLLECTION, fmt.tprintf("-out:%s", MCP_BIN), "-o:minimal"); code != 0 {
		return code
	}
	return run(MCP_BIN)
}

// builds/ is build output and library/ is derived data — both are gitignored
// and rebuild on the next run. builds/ itself is committed (a .gitkeep), so
// the directory is emptied rather than removed.
cmd_clean :: proc(args: []string) -> int {
	os.remove_all("builds")
	os.make_directory_all("builds")
	_ = os.write_entire_file("builds/.gitkeep", []u8{})
	fmt.println("mh: emptied builds/")
	if has_flag(args, "--all") {
		os.remove_all("moonhug/library")
		fmt.println("mh: removed moonhug/library/")
	}
	return 0
}
