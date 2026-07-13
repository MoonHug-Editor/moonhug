// Compiled shader blobs embedded at build time; the runtime picks the format
// the device accepts. MSL entry point is main0 (spirv-cross convention),
// SPIR-V is main. See shaders/compile.sh.
//
// Built-in shaders (one vertex shader, per-shader fragment): "unlit" and
// "lit", registered in init. shader_register is the seam a future custom
// shader importer plugs into — pipelines are name-keyed (see gfx.odin).
package gfx

import sdl "vendor:sdl3"

@(private) _WORLD_VERT_SPV := #load("shaders/compiled/world.vert.spv")
@(private) _WORLD_FRAG_SPV := #load("shaders/compiled/world.frag.spv")
@(private) _WORLD_VERT_MSL := #load("shaders/compiled/world.vert.msl")
@(private) _WORLD_FRAG_MSL := #load("shaders/compiled/world.frag.msl")
@(private) _LIT_FRAG_SPV   := #load("shaders/compiled/lit.frag.spv")
@(private) _LIT_FRAG_MSL   := #load("shaders/compiled/lit.frag.msl")

// num_* counts must match the shader's declared resources per SDL_GPU
// convention (vertex UBO set=1, fragment sampler2D set=2 in the GLSL source).
_create_shader :: proc(stage: sdl.GPUShaderStage, num_samplers, num_uniform_buffers: u32, spv, msl: []u8) -> ^sdl.GPUShader {
	formats := sdl.GetGPUShaderFormats(_gfx.device)
	info := sdl.GPUShaderCreateInfo{
		stage                = stage,
		num_samplers         = num_samplers,
		num_uniform_buffers  = num_uniform_buffers,
	}
	if .MSL in formats {
		info.format = {.MSL}
		info.entrypoint = "main0"
		info.code = raw_data(msl)
		info.code_size = len(msl)
	} else if .SPIRV in formats {
		info.format = {.SPIRV}
		info.entrypoint = "main"
		info.code = raw_data(spv)
		info.code_size = len(spv)
	} else {
		return nil
	}
	return sdl.CreateGPUShader(_gfx.device, info)
}
