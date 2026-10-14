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
// (plugins/engine/editor/importers/importer_shader.odin adds --reflect
// for binding indices). They stay separate: same tools, different output
// contracts.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SHADER_DIR :: "moonhug/libs/gfx/shaders"

// Stage comes from the second extension: "world.vert" -> vert.
SHADERS := []string{"world.vert", "world.frag", "lit.frag", "skin.comp", "fullscreen.vert", "blit.frag", "encode.frag", "normals.frag", "env_capture.frag", "env_prefilter.frag", "env_irradiance.frag", "skybox.frag"}

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
	return 0 if shaders_compile(force = true) else 1
}

// force compiles every shader. Otherwise a shader whose outputs are both newer
// than its source is skipped — builds call this on every run, and recompiling
// three unchanged shaders each time is pure latency.
shaders_compile :: proc(force := false) -> bool {
	out_dir, _ := filepath.join({SHADER_DIR, "compiled"}, context.temp_allocator)
	os.make_directory_all(out_dir)
	surface, _ := filepath.join({SHADER_DIR, "surface.glsl"}, context.temp_allocator)
	surface_main, _ := filepath.join({SHADER_DIR, "surface_main.glsl"}, context.temp_allocator)
	env_common, _ := filepath.join({SHADER_DIR, "env_common.glsl"}, context.temp_allocator)

	for name in SHADERS {
		stage := name[strings.last_index(name, ".") + 1:]
		src, _ := filepath.join({SHADER_DIR, fmt.tprintf("%s.glsl", name)}, context.temp_allocator)
		spv, _ := filepath.join({out_dir, fmt.tprintf("%s.spv", name)}, context.temp_allocator)
		msl, _ := filepath.join({out_dir, fmt.tprintf("%s.msl", name)}, context.temp_allocator)

		// The surface template files are inputs of every shader that includes
		// them (lit.frag), so a template edit recompiles.
		if !force && newer_than(spv, src) && newer_than(msl, src) && newer_than(spv, surface) && newer_than(spv, surface_main) && newer_than(spv, env_common) do continue

		// -I: `#include "surface.glsl"` resolves against the shader folder.
		if !step(fmt.tprintf("glslc %s", name), "glslc", fmt.tprintf("-fshader-stage=%s", stage), "-I", SHADER_DIR, src, "-o", spv) {
			return false
		}
		// MSL entry point becomes main0 (spirv-cross convention, matches shadercross).
		// --msl-decoration-binding keeps a GLSL binding as the Metal slot index
		// (the shadow map at binding 7 stays texture(7)), as the shader importer
		// does. Not for compute: its sets map to SDL's buffer order sequentially.
		cross := []string{"spirv-cross", "--msl", spv, "--output", msl}
		if stage != "comp" do cross = []string{"spirv-cross", "--msl", "--msl-decoration-binding", spv, "--output", msl}
		if !step(fmt.tprintf("spirv-cross %s", name), ..cross) {
			return false
		}
		fmt.printfln("compiled %s", name)
	}
	return true
}
