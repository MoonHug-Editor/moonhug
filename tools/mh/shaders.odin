package mh

// Built-in GLSL shaders to the per-backend binaries SDL_GPU consumes: SPIR-V
// (Vulkan) via glslc, MSL (Metal) via spirv-cross. DXIL is added when Windows
// rendering support lands.
//
// Output under compiled/ is COMMITTED, so contributors do not need this
// toolchain unless they change a shader — builds skip the step when it is
// missing. Toolchain: brew install shaderc spirv-cross
//
// The .glsl ASSET importer runs the same two tools with different flags
// (moonhug/engine_editor/asset_pipeline/importer_shader.odin adds --reflect
// for binding indices). They stay separate: same tools, different output
// contracts.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SHADER_DIR :: "moonhug/engine/gfx/shaders"

// Stage comes from the second extension: "world.vert" -> vert.
SHADERS := []string{"world.vert", "world.frag", "lit.frag"}

cmd_shaders :: proc(args: []string) -> int {
	missing := false
	for tool in ([]string{"glslc", "spirv-cross"}) {
		if !have(tool) {
			fmt.eprintfln("mh: %s is not on PATH", tool)
			missing = true
		}
	}
	if missing {
		fmt.eprintln("mh: shader authoring needs `brew install shaderc spirv-cross` (compiled output is committed, so this is only needed to CHANGE a shader)")
		return 1
	}
	return 0 if shaders_compile() else 1
}

shaders_compile :: proc() -> bool {
	out_dir, _ := filepath.join({SHADER_DIR, "compiled"}, context.temp_allocator)
	os.make_directory_all(out_dir)

	for name in SHADERS {
		stage := name[strings.last_index(name, ".") + 1:]
		src, _ := filepath.join({SHADER_DIR, fmt.tprintf("%s.glsl", name)}, context.temp_allocator)
		spv, _ := filepath.join({out_dir, fmt.tprintf("%s.spv", name)}, context.temp_allocator)
		msl, _ := filepath.join({out_dir, fmt.tprintf("%s.msl", name)}, context.temp_allocator)

		if !step(fmt.tprintf("glslc %s", name), "glslc", fmt.tprintf("-fshader-stage=%s", stage), src, "-o", spv) {
			return false
		}
		// MSL entry point becomes main0 (spirv-cross convention, matches shadercross)
		if !step(fmt.tprintf("spirv-cross %s", name), "spirv-cross", "--msl", spv, "--output", msl) {
			return false
		}
		fmt.printfln("compiled %s", name)
	}
	return true
}
