package mh

// Building and running the editor, the game, the tests and the MCP shim.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

EDITOR_BIN :: "builds/MoonHug" + EXE
TESTS_ASAN_BIN :: "builds/tests_asan" + EXE
MCP_BIN :: "builds/mcp_shim" + EXE

// Code generation, always before a build. Two steps: prune imports of removed
// package generators first — a stale one fails the prebuild compile before
// prebuild can heal the file itself — then run the generators.
// Both are compiled once into builds/tools/ and reused while unchanged
// (tools_cache.odin). Prebuild also depends on the package generators it
// compiles in, so their gen/ folders count as its sources.
// `docs` makes the reference generators write their pages under
// docs/reference, with source locations linked through docs_source_url.
// Their checks run either way.
prebuild :: proc(docs := false) -> bool {
	prune, pok := tool_bin("prune_package_gens", "moonhug/prebuild/prune_package_gens", {})
	if !pok || !step("prune", prune) do return false
	// Exit 2: the set of package generators changed and the prebuild rewrote
	// the file that imports them, so it is built again and run once more.
	for attempt in 0 ..< 2 {
		gen, gok := tool_bin("prebuild", "moonhug/prebuild", package_gen_dirs(), COLLECTION)
		if !gok do return false
		code := run(gen, "--docs", fmt.tprintf("--source-url=%s", docs_source_url())) if docs else run(gen)
		if code == 0 do return true
		if code == 2 && attempt == 0 do continue
		fmt.fprintfln(run_log if run_log != nil else os.stderr, "mh: prebuild failed (exit %d)", code)
		return false
	}
	return false
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
	append(&cmd, "odin", "build", "moonhug/editor", IGNORE_ATTRS, COLLECTION, VET)
	if debug do append(&cmd, "-debug")
	append(&cmd, fmt.tprintf("-out:%s", EDITOR_BIN))
	return step("editor build", ..cmd[:])
}

// Build then run as a CHILD process, not `odin run`: `odin run` keeps the
// ~1GB compiler resident for the whole life of the editor just to wait on it.
cmd_run :: proc(args: []string) -> int {
	return launch_editor("run")
}

cmd_debug :: proc(args: []string) -> int {
	return launch_editor("debug")
}

// The file that tells a running editor its replacement is built. Lives under
// builds/ so `mh clean` removes a stale one.
RELAUNCH_MARKER :: "builds/relaunch_ready"

// Build and launch the editor for `mode` ("run" or "debug"). The editor gets
// MH_LAUNCH=<mode> so its Relaunch button can rerun this exact command.
//
// Relaunch handshake (editor/relaunch.odin): the editor spawns `mh <mode>`
// with MH_RELAUNCH_PID set to its own pid and keeps running while the build
// goes. On a successful build this writes RELAUNCH_MARKER, waits for that
// editor to exit, removes the marker and launches the new one. A failed build
// writes no marker, so the old editor stays up with the compiler output in
// its terminal.
launch_editor :: proc(mode: string) -> int {
	if !build_editor(mode == "debug") do return 1

	if pid_str, relaunching := os.lookup_env("MH_RELAUNCH_PID", context.temp_allocator); relaunching {
		if pid, ok := strconv.parse_int(pid_str); ok {
			_ = os.write_entire_file(RELAUNCH_MARKER, "ready")
			fmt.printfln("mh: built, waiting for editor %d to exit", pid)
			// Poll instead of waiting: the old editor is not our child.
			deadline := time.now()._nsec + i64(15 * time.Second)
			for process_alive(pid) && time.now()._nsec < deadline {
				time.sleep(50 * time.Millisecond)
			}
			_ = os.remove(RELAUNCH_MARKER)
		}
	}

	env := make([dynamic]string, context.temp_allocator)
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			// Never inherit the handshake pid: the new editor is not relaunching.
			if strings.has_prefix(kv, "MH_RELAUNCH_PID=") || strings.has_prefix(kv, "MH_LAUNCH=") do continue
			append(&env, kv)
		}
	}
	append(&env, fmt.tprintf("MH_LAUNCH=%s", mode))
	return run_env(env[:], EDITOR_BIN)
}

cmd_build :: proc(args: []string) -> int {
	if has_flag(args, "--no-plugins") do return 0 if build_without_plugins() else 1
	if !build_editor(has_flag(args, "--debug")) do return 1
	fmt.printfln("mh: built %s", EDITOR_BIN)
	return 0
}

cmd_prebuild :: proc(args: []string) -> int {
	return 0 if prebuild() else 1
}

// Gathers dependencies into each plugin's mh_plugin.json (docs/core/Plugins.md,
// "Plugin manifest"). The work lives beside prebuild, which reads the same
// imports: this tool imports nothing from the moonhug collection.
cmd_deps :: proc(args: []string) -> int {
	bin, ok := tool_bin("gather_plugin_deps", "moonhug/prebuild/gather_plugin_deps", {"moonhug/prebuild/gen_facts"}, COLLECTION)
	if !ok do return 1
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, bin)
	append(&cmd, ..args)
	return 0 if step("deps", ..cmd[:]) else 1
}

// -define:ODIN_TEST_THREADS=1 keeps tests serial: they share the asset db and
// fixture files on disk. Codegen runs first: the test binary compiles the
// generated registrations, and a stale one fails the compile against renamed
// types.
cmd_test :: proc(args: []string) -> int {
	if !prebuild() do return 1
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "test", "moonhug/tests", "-all-packages", IGNORE_ATTRS, COLLECTION, VET, "-define:ODIN_TEST_THREADS=1")
	if name := flag_value(args, "--name"); name != "" {
		append(&cmd, fmt.tprintf("-define:ODIN_TEST_NAMES=%s", name))
	}
	return run(..cmd[:])
}

// The suite under AddressSanitizer: a read or write of freed heap memory or
// past an allocation's end aborts the run at the first one, with the stack
// of the access, the free and the allocation. It is about four times slower
// than `test`, so it is for the release workflow (.github/workflows) and for
// after a change to allocators, pools, caches or object lifetimes, not the
// edit-and-run loop. Two gaps: leak detection is off, macOS on arm64 has
// none, and the temp allocator is invisible to it, Odin keeps the arena's
// sanitizer hooks off, so memory kept past a frame goes unnoticed.
cmd_test_asan :: proc(args: []string) -> int {
	if !prebuild() do return 1
	os.make_directory_all("builds")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", "build", "moonhug/tests", "-build-mode:test", "-all-packages", IGNORE_ATTRS, COLLECTION, VET, "-define:ODIN_TEST_THREADS=1", "-debug", "-sanitize:address", fmt.tprintf("-out:%s", TESTS_ASAN_BIN))
	if name := flag_value(args, "--name"); name != "" {
		append(&cmd, fmt.tprintf("-define:ODIN_TEST_NAMES=%s", name))
	}
	if !step("sanitizer test build", ..cmd[:]) do return 1

	// The caller's ASAN_OPTIONS win over the defaults.
	env := make([dynamic]string, context.temp_allocator)
	has_options := false
	if cur, err := os.environ(context.temp_allocator); err == nil {
		for kv in cur {
			if strings.has_prefix(kv, "ASAN_OPTIONS=") do has_options = true
			append(&env, kv)
		}
	}
	if !has_options do append(&env, "ASAN_OPTIONS=detect_leaks=0:halt_on_error=1")
	return run_env(env[:], TESTS_ASAN_BIN)
}

// The MCP stdio server the client spawns (.mcp.json, docs/core/McpBridge.md).
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
