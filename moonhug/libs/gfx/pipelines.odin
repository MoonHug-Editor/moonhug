// Graphics pipelines, keyed by shader name. Two families:
//
// - World shaders (shader_register): the built-in world vertex stage plus a
//   fragment shader, one pipeline per _Pipeline_Kind. All of them share the
//   Vertex format and the _Uniform layout (pass.odin), which is what lets
//   pass_end switch shaders per draw without re-plumbing uniforms.
// - Fullscreen shaders (fullscreen_register): the fullscreen-triangle vertex
//   stage plus a fragment shader, one pipeline. Used by draw_fullscreen for
//   blits and post effects.
//
// A pipeline is bound to the color target's pixel format, so each entry keeps
// one set per Target_Format and builds a set the first time a pass of that
// format draws with the shader. Registering a shader builds the LDR set right
// away, so a shader that cannot compile fails at registration, not mid-frame.
package gfx

import "base:runtime"
import "core:strings"
import sdl "vendor:sdl3"

_Shader_Set :: [_Pipeline_Kind]^sdl.GPUGraphicsPipeline

@(private)
_Shader_Entry :: struct {
	vert, frag:    ^sdl.GPUShader, // kept alive so later formats can build their set
	frag_samplers: u32,            // sampler slots the fragment stage declares
	sets:          [Target_Format]_Shader_Set,
	built:         [Target_Format]bool,
}

@(private)
_Fullscreen_Entry :: struct {
	frag:      ^sdl.GPUShader,
	pipelines: [Target_Format]^sdl.GPUGraphicsPipeline,
}

@(private) _FULLSCREEN_VERT_SPV := #load("shaders/compiled/fullscreen.vert.spv")
@(private) _FULLSCREEN_VERT_MSL := #load("shaders/compiled/fullscreen.vert.msl")
@(private) _ENCODE_FRAG_SPV     := #load("shaders/compiled/encode.frag.spv")
@(private) _ENCODE_FRAG_MSL     := #load("shaders/compiled/encode.frag.msl")
@(private) _BLIT_FRAG_SPV       := #load("shaders/compiled/blit.frag.spv")
@(private) _BLIT_FRAG_MSL       := #load("shaders/compiled/blit.frag.msl")
@(private) _NORMALS_FRAG_SPV    := #load("shaders/compiled/normals.frag.spv")
@(private) _NORMALS_FRAG_MSL    := #load("shaders/compiled/normals.frag.msl")

@(private)
_create_pipelines :: proc() -> bool {
	// Registries for the process: their names are copied and freed with the
	// map's own allocator, whatever allocator a registering caller runs
	// under (a cache pinned to the default one, a frame's tracking one).
	_gfx.shaders = make(map[string]_Shader_Entry, runtime.default_allocator())
	_gfx.fullscreen = make(map[string]_Fullscreen_Entry, runtime.default_allocator())
	_gfx.fullscreen_vert = _create_shader(.VERTEX, 0, 0, _FULLSCREEN_VERT_SPV, _FULLSCREEN_VERT_MSL)
	if _gfx.fullscreen_vert == nil do return false
	if !shader_register(DEFAULT_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _WORLD_FRAG_SPV, _WORLD_FRAG_MSL) do return false
	if !shader_register(LIT_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _LIT_FRAG_SPV, _LIT_FRAG_MSL, frag_samplers = SHADOW_SAMPLER_SLOT + 1, frag_uniform_buffers = 2) do return false
	if !shader_register(NORMALS_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _NORMALS_FRAG_SPV, _NORMALS_FRAG_MSL) do return false
	if !fullscreen_register(BLIT_SHADER, _BLIT_FRAG_SPV, _BLIT_FRAG_MSL, 1, 0) do return false
	if !fullscreen_register(ENCODE_SHADER, _ENCODE_FRAG_SPV, _ENCODE_FRAG_MSL, 1, 0) do return false
	return true
}

@(private)
_pipelines_shutdown :: proc() {
	for name, &e in _gfx.shaders {
		_shader_entry_release(&e)
		delete(name, _gfx.shaders.allocator)
	}
	delete(_gfx.shaders)
	for name, &e in _gfx.fullscreen {
		_fullscreen_entry_release(&e)
		delete(name, _gfx.fullscreen.allocator)
	}
	delete(_gfx.fullscreen)
	if _gfx.fullscreen_vert != nil do sdl.ReleaseGPUShader(_gfx.device, _gfx.fullscreen_vert)
}

// The pixel format a Target_Format stands for on this device.
target_pixel_format :: proc(f: Target_Format) -> sdl.GPUTextureFormat {
	switch f {
	case .Display: return _gfx.swapchain_format
	case .HDR:     return .R16G16B16A16_FLOAT
	case .LDR:     return .R8G8B8A8_UNORM_SRGB
	}
	return _gfx.swapchain_format
}

shader_exists :: proc(name: string) -> bool {
	return name in _gfx.shaders
}

// User shaders are fragment-only: the vertex stage is always the built-in
// world vertex shader (fixed Vertex format + _Uniform contract). Resource
// counts come from import-time reflection, not convention.
shader_register_fragment :: proc(name: string, frag_spv, frag_msl: []u8, num_samplers, num_uniform_buffers: u32) -> bool {
	return shader_register(name, _WORLD_VERT_SPV, _WORLD_VERT_MSL, frag_spv, frag_msl,
		frag_samplers = num_samplers, frag_uniform_buffers = num_uniform_buffers)
}

// Releases the shader's pipelines (SDL_GPU defers actual destruction past
// in-flight frames). Used by shader hot-reload; unknown names are a no-op.
shader_unregister :: proc(name: string) {
	e, ok := &_gfx.shaders[name]
	if !ok do return
	_shader_entry_release(e)
	key, _ := delete_key(&_gfx.shaders, name)
	delete(key, _gfx.shaders.allocator)
}

// Registers a vertex+fragment shader pair under `name` (draw_mesh's shader
// parameter) and builds its LDR pipeline set. The vertex stage must declare
// 1 UBO (_Uniform layout); fragment resource counts must match the shader's
// declarations (sampler2D at set=2, optional Light UBO at set=3).
// Re-registering a name is an error (false).
shader_register :: proc(name: string, vert_spv, vert_msl, frag_spv, frag_msl: []u8, frag_samplers: u32 = 1, frag_uniform_buffers: u32 = 0) -> bool {
	if name in _gfx.shaders do return false
	e := _Shader_Entry{
		vert          = _create_shader(.VERTEX, 0, 1, vert_spv, vert_msl),
		frag          = _create_shader(.FRAGMENT, frag_samplers, frag_uniform_buffers, frag_spv, frag_msl),
		frag_samplers = frag_samplers,
	}
	if e.vert == nil || e.frag == nil || !_shader_set_build(&e, .LDR) {
		_shader_entry_release(&e)
		return false
	}
	_gfx.shaders[strings.clone(name, _gfx.shaders.allocator)] = e
	return true
}

// The pipeline a draw binds: `name` ("" = DEFAULT_SHADER, unknown = DEFAULT_SHADER
// too, so a missing user shader draws unlit rather than nothing), for the
// pass's target format and the draw's kind. Builds the format's set on first use.
@(private)
_shader_pipeline :: proc(name: string, format: Target_Format, kind: _Pipeline_Kind) -> ^sdl.GPUGraphicsPipeline {
	e, ok := &_gfx.shaders[name]
	if !ok do e = &_gfx.shaders[DEFAULT_SHADER]
	if !e.built[format] && !_shader_set_build(e, format) do return nil
	return e.sets[format][kind]
}

// Sampler slots the named shader's fragment stage declares ("" and unknown
// names resolve as _shader_pipeline does).
@(private)
_shader_samplers :: proc(name: string) -> u32 {
	e, ok := &_gfx.shaders[name]
	if !ok do e = &_gfx.shaders[DEFAULT_SHADER]
	return e.frag_samplers
}

@(private)
_shader_entry_release :: proc(e: ^_Shader_Entry) {
	for f in Target_Format {
		if !e.built[f] do continue
		for p in e.sets[f] {
			if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
		}
		e.built[f] = false
	}
	if e.vert != nil do sdl.ReleaseGPUShader(_gfx.device, e.vert)
	if e.frag != nil do sdl.ReleaseGPUShader(_gfx.device, e.frag)
	e.vert, e.frag = nil, nil
}

@(private)
_shader_set_build :: proc(e: ^_Shader_Entry, format: Target_Format) -> bool {
	buffer_desc := sdl.GPUVertexBufferDescription{
		slot       = 0,
		pitch      = size_of(Vertex),
		input_rate = .VERTEX,
	}
	attributes := [5]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, position))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
		{location = 3, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Vertex, color))},
		{location = 4, buffer_slot = 0, format = .FLOAT4, offset = u32(offset_of(Vertex, tangent))},
	}
	color_target := sdl.GPUColorTargetDescription{
		format      = target_pixel_format(format),
		blend_state = _ALPHA_BLEND,
	}
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = e.vert,
		fragment_shader = e.frag,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffer_desc,
			num_vertex_buffers         = 1,
			vertex_attributes          = raw_data(attributes[:]),
			num_vertex_attributes      = len(attributes),
		},
		primitive_type = .TRIANGLELIST,
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets         = 1,
			depth_stencil_format      = _DEPTH_FORMAT,
			has_depth_stencil_target  = true,
		},
	}

	make_pipeline :: proc(info: ^sdl.GPUGraphicsPipelineCreateInfo, primitive: sdl.GPUPrimitiveType, depth_test, depth_write: bool, fill := sdl.GPUFillMode.FILL) -> ^sdl.GPUGraphicsPipeline {
		info.primitive_type = primitive
		info.rasterizer_state.fill_mode = fill
		info.depth_stencil_state = {
			compare_op         = .LESS_OR_EQUAL,
			enable_depth_test  = depth_test,
			enable_depth_write = depth_write,
		}
		return sdl.CreateGPUGraphicsPipeline(_gfx.device, info^)
	}

	set: _Shader_Set
	set[.Tris]          = make_pipeline(&info, .TRIANGLELIST, true, false)
	set[.Tris_Depth]    = make_pipeline(&info, .TRIANGLELIST, true, true)
	set[.Tris_Overlay]  = make_pipeline(&info, .TRIANGLELIST, false, false)
	set[.Tris_Wire]     = make_pipeline(&info, .TRIANGLELIST, true, false, .LINE)
	set[.Lines]         = make_pipeline(&info, .LINELIST, true, false)
	set[.Lines_Depth]   = make_pipeline(&info, .LINELIST, true, true)
	set[.Lines_Overlay] = make_pipeline(&info, .LINELIST, false, false)
	for p in set {
		if p == nil {
			for q in set {
				if q != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, q)
			}
			return false
		}
	}
	e.sets[format] = set
	e.built[format] = true
	return true
}

@(private)
_ALPHA_BLEND :: sdl.GPUColorTargetBlendState{
	src_color_blendfactor = .SRC_ALPHA,
	dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
	color_blend_op        = .ADD,
	src_alpha_blendfactor = .ONE,
	dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
	alpha_blend_op        = .ADD,
	enable_blend          = true,
}

// --- Fullscreen shaders ---------------------------------------------------

fullscreen_exists :: proc(name: string) -> bool {
	return name in _gfx.fullscreen
}

// Registers a fragment shader drawn over the whole target by draw_fullscreen.
// It receives uv in location 0, its inputs as samplers at set=2 and an
// optional property block at set=3 binding=1 (slot 1, as a material's). No
// blending, no depth.
fullscreen_register :: proc(name: string, frag_spv, frag_msl: []u8, num_samplers, num_uniform_buffers: u32) -> bool {
	if name in _gfx.fullscreen do return false
	e := _Fullscreen_Entry{frag = _create_shader(.FRAGMENT, num_samplers, num_uniform_buffers, frag_spv, frag_msl)}
	if e.frag == nil do return false
	if _fullscreen_build(&e, .LDR) == nil {
		_fullscreen_entry_release(&e)
		return false
	}
	_gfx.fullscreen[strings.clone(name, _gfx.fullscreen.allocator)] = e
	return true
}

fullscreen_unregister :: proc(name: string) {
	e, ok := &_gfx.fullscreen[name]
	if !ok do return
	_fullscreen_entry_release(e)
	key, _ := delete_key(&_gfx.fullscreen, name)
	delete(key, _gfx.fullscreen.allocator)
}

@(private)
_fullscreen_pipeline :: proc(name: string, format: Target_Format) -> ^sdl.GPUGraphicsPipeline {
	e, ok := &_gfx.fullscreen[name]
	if !ok do return nil
	if e.pipelines[format] == nil do e.pipelines[format] = _fullscreen_build(e, format)
	return e.pipelines[format]
}

@(private)
_fullscreen_entry_release :: proc(e: ^_Fullscreen_Entry) {
	for p in e.pipelines {
		if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
	}
	if e.frag != nil do sdl.ReleaseGPUShader(_gfx.device, e.frag)
	e^ = {}
}

// Depth is attached but neither tested nor written: every gfx pass has a
// depth target, and the pipeline's target layout has to match the pass's.
@(private)
_fullscreen_build :: proc(e: ^_Fullscreen_Entry, format: Target_Format) -> ^sdl.GPUGraphicsPipeline {
	color_target := sdl.GPUColorTargetDescription{format = target_pixel_format(format)}
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = _gfx.fullscreen_vert,
		fragment_shader = e.frag,
		primitive_type  = .TRIANGLELIST,
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets         = 1,
			depth_stencil_format      = _DEPTH_FORMAT,
			has_depth_stencil_target  = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(_gfx.device, info)
}
