package mh

// One-time build of the vendored C libraries this repo links against. Odin
// ships their SOURCE and expects you to build them once per installation.
//
// Odin's own vendor folders carry a build_*.sh and a build.bat per library —
// which is exactly the split this tool exists to avoid, so setup picks the one
// that matches the host. stb and cgltf are plain makefiles; box2d needs cmake;
// box3d needs clang.
//
// Already-built libraries are skipped, so this is safe to re-run.

import "core:fmt"
import "core:os"

Vendor_Lib :: struct {
	name:     string,
	// Existing file that means "already built".
	artifact: string,
	// Directory the build runs in.
	dir:      string,
	// Command, host-specific.
	unix_cmd: []string,
	win_cmd:  []string,
	note:     string,
}

vendor_libs :: proc() -> []Vendor_Lib {
	lib_dir := "darwin" when ODIN_OS == .Darwin else "linux"
	stb_artifact := fmt.tprintf("stb/lib/%s/stb_image.a", lib_dir) if ODIN_OS != .Windows else "stb/lib/stb_image.lib"
	cgltf_artifact := fmt.tprintf("cgltf/lib/%s/cgltf.a", lib_dir) if ODIN_OS != .Windows else "cgltf/lib/cgltf.lib"

	libs := make([dynamic]Vendor_Lib, context.temp_allocator)
	append(&libs,
		Vendor_Lib {
			name = "stb",
			artifact = stb_artifact,
			dir = odin_vendor("stb", "src"),
			unix_cmd = {"make"},
			win_cmd = {"cmd", "/C", "build.bat"},
			note = "image decoding",
		},
		Vendor_Lib {
			name = "cgltf",
			artifact = cgltf_artifact,
			dir = odin_vendor("cgltf", "src"),
			unix_cmd = {"make"},
			win_cmd = {"cmd", "/C", "build.bat"},
			note = "glTF mesh import",
		},
		Vendor_Lib {
			name = "box2d",
			artifact = fmt.tprintf("box2d/lib/box2d_%s_%s.a", lib_dir, "arm64" when ODIN_ARCH == .arm64 else "amd64"),
			dir = odin_vendor("box2d"),
			unix_cmd = {"sh", "build_box2d.sh"},
			win_cmd = {"cmd", "/C", "build_box2d.bat"},
			note = "physics2d package, needs cmake (a WASM warning is harmless)",
		},
		Vendor_Lib {
			name = "box3d",
			artifact = fmt.tprintf("box3d/lib/%s", lib_dir),
			dir = odin_vendor("box3d", "src"),
			unix_cmd = {"sh", "build.sh"},
			win_cmd = {"cmd", "/C", "build.bat"},
			note = "physics3d package, clang only",
		},
	)
	return libs[:]
}

cmd_setup :: proc(args: []string) -> int {
	force := has_flag(args, "--force")
	failed := 0
	built := 0

	fmt.printfln("mh: vendored libraries under %s", odin_vendor())
	for lib in vendor_libs() {
		artifact := odin_vendor(lib.artifact)
		if !force && os.exists(artifact) {
			fmt.printfln("  %-7s already built", lib.name)
			continue
		}
		if !os.is_dir(lib.dir) {
			fmt.eprintfln("  %-7s SKIPPED — %s does not exist in this Odin installation", lib.name, lib.dir)
			continue
		}
		fmt.printfln("  %-7s building (%s)", lib.name, lib.note)
		cmd := lib.unix_cmd
		when ODIN_OS == .Windows do cmd = lib.win_cmd
		if code := run_in(lib.dir, ..cmd); code != 0 {
			fmt.eprintfln("  %-7s FAILED (exit %d)", lib.name, code)
			failed += 1
			continue
		}
		built += 1
	}

	fmt.println()
	if !have("glslc") || !have("spirv-cross") {
		fmt.println("mh: shader toolchain absent (glslc, spirv-cross) — optional, compiled shaders are committed. Needed only to CHANGE a shader: brew install shaderc spirv-cross")
	}
	if failed > 0 {
		fmt.eprintfln("mh: %d vendored librar%s failed to build", failed, "y" if failed == 1 else "ies")
		return 1
	}
	fmt.printfln("mh: setup complete (%d built). Next: odin run tools/mh -- run", built)
	return 0
}
