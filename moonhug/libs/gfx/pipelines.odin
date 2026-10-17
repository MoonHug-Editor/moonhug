// Graphics pipelines, keyed by shader name. Two families:
//
// - World shaders (shader_register): the built-in world vertex stage plus a
//   fragment shader, one pipeline per _Pipeline_Kind. All of them share the
//   Vertex format (slot 0), the _Instance format (slot 1) and the _Uniform
//   layout (pass.odin), which is what lets pass_end switch shaders per draw
//   without re-plumbing uniforms.
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
	// The fragment stage of depth-only pipelines: the shader's caster variant
	// (alpha clipping, no lighting), nil for depth.frag. The built-in caster
	// is shared, so only a caster the entry created is released with it.
	caster:          ^sdl.GPUShader,
	caster_samplers: u32,
	owns_caster:     bool,
	sets:          [Target_Format]_Shader_Set,
	built:         [Target_Format]bool,
	// Mesh draws that cull or are mirrored, by opaque (0, .Tris_Depth) or
	// blended (1, .Tris), cull mode and mirroring (1 = clockwise front
	// faces): built the first time a pass of the format draws one. The sets
	// hold the unculled, unmirrored pipelines.
	faced:         [Target_Format][2][Cull][2]^sdl.GPUGraphicsPipeline,
}

@(private)
_Fullscreen_Entry :: struct {
	frag:      ^sdl.GPUShader,
	samplers:  u32, // the inputs the fragment stage declares (draw_fullscreen checks them)
	pipelines: [Target_Format]^sdl.GPUGraphicsPipeline,
	// draw_sky: depth-tested at the far plane, no depth write.
	sky:       [Target_Format]^sdl.GPUGraphicsPipeline,
	// cubemap_render: an HDR color target, no depth attachment.
	cube:      ^sdl.GPUGraphicsPipeline,
}

@(private) _FULLSCREEN_VERT_SPV := #load("shaders/compiled/fullscreen.vert.spv")
@(private) _FULLSCREEN_VERT_MSL := #load("shaders/compiled/fullscreen.vert.msl")
@(private) _ENV_CAPTURE_FRAG_SPV    := #load("shaders/compiled/env_capture.frag.spv")
@(private) _ENV_CAPTURE_FRAG_MSL    := #load("shaders/compiled/env_capture.frag.msl")
@(private) _ENV_PREFILTER_FRAG_SPV  := #load("shaders/compiled/env_prefilter.frag.spv")
@(private) _ENV_PREFILTER_FRAG_MSL  := #load("shaders/compiled/env_prefilter.frag.msl")
@(private) _ENV_IRRADIANCE_FRAG_SPV := #load("shaders/compiled/env_irradiance.frag.spv")
@(private) _ENV_IRRADIANCE_FRAG_MSL := #load("shaders/compiled/env_irradiance.frag.msl")
@(private) _SKYBOX_FRAG_SPV         := #load("shaders/compiled/skybox.frag.spv")
@(private) _SKYBOX_FRAG_MSL         := #load("shaders/compiled/skybox.frag.msl")
@(private) _ENCODE_FRAG_SPV     := #load("shaders/compiled/encode.frag.spv")
@(private) _ENCODE_FRAG_MSL     := #load("shaders/compiled/encode.frag.msl")
@(private) _BLIT_FRAG_SPV       := #load("shaders/compiled/blit.frag.spv")
@(private) _BLIT_FRAG_MSL       := #load("shaders/compiled/blit.frag.msl")
@(private) _NORMALS_FRAG_SPV    := #load("shaders/compiled/normals.frag.spv")
@(private) _NORMALS_FRAG_MSL    := #load("shaders/compiled/normals.frag.msl")
@(private) _DEPTH_FRAG_SPV      := #load("shaders/compiled/depth.frag.spv")
@(private) _DEPTH_FRAG_MSL      := #load("shaders/compiled/depth.frag.msl")
@(private) _CASTER_FRAG_SPV     := #load("shaders/compiled/caster.frag.spv")
@(private) _CASTER_FRAG_MSL     := #load("shaders/compiled/caster.frag.msl")
@(private) _DEPTH_VIEW_FRAG_SPV := #load("shaders/compiled/depth_view.frag.spv")
@(private) _DEPTH_VIEW_FRAG_MSL := #load("shaders/compiled/depth_view.frag.msl")
@(private) _TAA_FRAG_SPV        := #load("shaders/compiled/taa.frag.spv")
@(private) _TAA_FRAG_MSL        := #load("shaders/compiled/taa.frag.msl")
@(private) _MOTION_FRAG_SPV     := #load("shaders/compiled/motion.frag.spv")
@(private) _MOTION_FRAG_MSL     := #load("shaders/compiled/motion.frag.msl")
@(private) _SSAO_FRAG_SPV       := #load("shaders/compiled/ssao.frag.spv")
@(private) _SSAO_FRAG_MSL       := #load("shaders/compiled/ssao.frag.msl")
@(private) _SSAO_BLUR_FRAG_SPV  := #load("shaders/compiled/ssao_blur.frag.spv")
@(private) _SSAO_BLUR_FRAG_MSL  := #load("shaders/compiled/ssao_blur.frag.msl")
@(private) _SSR_FRAG_SPV        := #load("shaders/compiled/ssr.frag.spv")
@(private) _SSR_FRAG_MSL        := #load("shaders/compiled/ssr.frag.msl")

@(private)
_create_pipelines :: proc() -> bool {
	// Registries for the process: their names are copied and freed with the
	// map's own allocator, whatever allocator a registering caller runs
	// under (a cache pinned to the default one, a frame's tracking one).
	_gfx.shaders = make(map[string]_Shader_Entry, runtime.default_allocator())
	_gfx.fullscreen = make(map[string]_Fullscreen_Entry, runtime.default_allocator())
	_gfx.fullscreen_vert = _create_shader(.VERTEX, 0, 0, _FULLSCREEN_VERT_SPV, _FULLSCREEN_VERT_MSL)
	if _gfx.fullscreen_vert == nil do return false
	// Depth passes: depth.frag for a shader with no caster, the template's
	// caster variant for the built-in Lit and Unlit (alpha clipping).
	_gfx.depth_frag = _create_shader(.FRAGMENT, 0, 0, _DEPTH_FRAG_SPV, _DEPTH_FRAG_MSL)
	_gfx.caster_frag = _create_shader(.FRAGMENT, MAX_FRAGMENT_SAMPLERS, LIGHT_LIST_SLOT + 1, _CASTER_FRAG_SPV, _CASTER_FRAG_MSL)
	if _gfx.depth_frag == nil || _gfx.caster_frag == nil do return false
	// The world shaders that clip declare the per-draw block (DRAW_UNIFORM_SLOT).
	if !shader_register(DEFAULT_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _WORLD_FRAG_SPV, _WORLD_FRAG_MSL, frag_uniform_buffers = DRAW_UNIFORM_SLOT + 1) do return false
	// The surface template declares every block: lights, material, draw, light list.
	if !shader_register(LIT_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _LIT_FRAG_SPV, _LIT_FRAG_MSL, frag_samplers = MAX_FRAGMENT_SAMPLERS, frag_uniform_buffers = LIGHT_LIST_SLOT + 1) do return false
	if !shader_register(NORMALS_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _NORMALS_FRAG_SPV, _NORMALS_FRAG_MSL, frag_uniform_buffers = DRAW_UNIFORM_SLOT + 1) do return false
	if !shader_register(DEPTH_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _DEPTH_FRAG_SPV, _DEPTH_FRAG_MSL, frag_samplers = 0) do return false
	if !shader_register(MOTION_SHADER, _WORLD_VERT_SPV, _WORLD_VERT_MSL, _MOTION_FRAG_SPV, _MOTION_FRAG_MSL, frag_samplers = 0, frag_uniform_buffers = 2) do return false
	for name in ([]string{DEFAULT_SHADER, LIT_SHADER}) {
		e := &_gfx.shaders[name]
		e.caster = _gfx.caster_frag
		e.caster_samplers = MAX_FRAGMENT_SAMPLERS
	}
	if !fullscreen_register(DEPTH_VIEW_SHADER, _DEPTH_VIEW_FRAG_SPV, _DEPTH_VIEW_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(TAA_SHADER, _TAA_FRAG_SPV, _TAA_FRAG_MSL, 4, 2) do return false
	if !fullscreen_register(SSAO_SHADER, _SSAO_FRAG_SPV, _SSAO_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(SSAO_BLUR_SHADER, _SSAO_BLUR_FRAG_SPV, _SSAO_BLUR_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(SSR_SHADER, _SSR_FRAG_SPV, _SSR_FRAG_MSL, 3, 2) do return false
	if !fullscreen_register(BLIT_SHADER, _BLIT_FRAG_SPV, _BLIT_FRAG_MSL, 1, 0) do return false
	if !fullscreen_register(ENCODE_SHADER, _ENCODE_FRAG_SPV, _ENCODE_FRAG_MSL, 1, 0) do return false
	if !fullscreen_register(ENV_CAPTURE_SHADER, _ENV_CAPTURE_FRAG_SPV, _ENV_CAPTURE_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(ENV_PREFILTER_SHADER, _ENV_PREFILTER_FRAG_SPV, _ENV_PREFILTER_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(ENV_IRRADIANCE_SHADER, _ENV_IRRADIANCE_FRAG_SPV, _ENV_IRRADIANCE_FRAG_MSL, 1, 2) do return false
	if !fullscreen_register(SKYBOX_SHADER, _SKYBOX_FRAG_SPV, _SKYBOX_FRAG_MSL, 1, 2) do return false
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
	if _gfx.depth_frag != nil do sdl.ReleaseGPUShader(_gfx.device, _gfx.depth_frag)
	if _gfx.caster_frag != nil do sdl.ReleaseGPUShader(_gfx.device, _gfx.caster_frag)
}

// The pixel format a Target_Format stands for on this device.
target_pixel_format :: proc(f: Target_Format) -> sdl.GPUTextureFormat {
	switch f {
	case .Display: return _gfx.swapchain_format
	case .HDR:     return .R16G16B16A16_FLOAT
	case .LDR:     return .R8G8B8A8_UNORM_SRGB
	case .Depth:   return .INVALID // no color
	}
	return _gfx.swapchain_format
}

shader_exists :: proc(name: string) -> bool {
	return name in _gfx.shaders
}

// User shaders are fragment-only: the vertex stage is always the built-in
// world vertex shader (fixed Vertex and _Instance formats + _Uniform contract). Resource
// counts come from import-time reflection, not convention. `caster` is the
// shader's depth-pass variant (a surface shader's caster, alpha clipping),
// empty for none: depth passes then draw it with depth.frag.
shader_register_fragment :: proc(name: string, frag_spv, frag_msl: []u8, num_samplers, num_uniform_buffers: u32, caster_spv: []u8 = nil, caster_msl: []u8 = nil, caster_samplers: u32 = 0, caster_uniform_buffers: u32 = 0) -> bool {
	return shader_register(name, _WORLD_VERT_SPV, _WORLD_VERT_MSL, frag_spv, frag_msl,
		frag_samplers = num_samplers, frag_uniform_buffers = num_uniform_buffers,
		caster_spv = caster_spv, caster_msl = caster_msl, caster_samplers = caster_samplers, caster_uniform_buffers = caster_uniform_buffers)
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
shader_register :: proc(name: string, vert_spv, vert_msl, frag_spv, frag_msl: []u8, frag_samplers: u32 = 1, frag_uniform_buffers: u32 = 0, caster_spv: []u8 = nil, caster_msl: []u8 = nil, caster_samplers: u32 = 0, caster_uniform_buffers: u32 = 0) -> bool {
	if name in _gfx.shaders do return false
	e := _Shader_Entry{
		vert          = _create_shader(.VERTEX, 0, 1, vert_spv, vert_msl),
		frag          = _create_shader(.FRAGMENT, frag_samplers, frag_uniform_buffers, frag_spv, frag_msl),
		frag_samplers = frag_samplers,
	}
	if len(caster_spv) > 0 || len(caster_msl) > 0 {
		e.caster = _create_shader(.FRAGMENT, caster_samplers, caster_uniform_buffers, caster_spv, caster_msl)
		e.caster_samplers = caster_samplers
		e.owns_caster = true
		if e.caster == nil {
			_shader_entry_release(&e)
			return false
		}
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
// pass's target format, the draw's kind, and its cull mode and mirroring
// (meshes only, draw_mesh). Builds the format's set, or the mesh pipeline
// with that cull and winding, on first use.
@(private)
_shader_pipeline :: proc(name: string, format: Target_Format, kind: _Pipeline_Kind, cull: Cull, mirrored: bool) -> ^sdl.GPUGraphicsPipeline {
	e, ok := &_gfx.shaders[name]
	if !ok do e = &_gfx.shaders[DEFAULT_SHADER]
	if cull != .None || mirrored {
		assert(kind == .Tris_Depth || kind == .Tris, "gfx: only mesh draws cull or mirror")
		p := &e.faced[format][kind == .Tris ? 1 : 0][cull][int(mirrored)]
		if p^ == nil do p^ = _world_pipeline_create(e, format, .TRIANGLELIST, true, kind == .Tris_Depth, cull = cull, mirrored = mirrored)
		return p^
	}
	if !e.built[format] && !_shader_set_build(e, format) do return nil
	return e.sets[format][kind]
}

// Sampler slots the named shader's fragment stage declares in a pass of
// `format` ("" and unknown names resolve as _shader_pipeline does): in a
// depth-only pass, its caster's, or none for depth.frag.
@(private)
_shader_samplers :: proc(name: string, format: Target_Format) -> u32 {
	e, ok := &_gfx.shaders[name]
	if !ok do e = &_gfx.shaders[DEFAULT_SHADER]
	if format == .Depth do return e.caster != nil ? e.caster_samplers : 0
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
	for &by_blend in e.faced {
		for &by_cull in by_blend {
			for &by_winding in by_cull {
				for &p in by_winding {
					if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
					p = nil
				}
			}
		}
	}
	if e.vert != nil do sdl.ReleaseGPUShader(_gfx.device, e.vert)
	if e.frag != nil do sdl.ReleaseGPUShader(_gfx.device, e.frag)
	if e.owns_caster && e.caster != nil do sdl.ReleaseGPUShader(_gfx.device, e.caster)
	e.vert, e.frag, e.caster = nil, nil, nil
}

@(private)
_shader_set_build :: proc(e: ^_Shader_Entry, format: Target_Format) -> bool {
	set: _Shader_Set
	set[.Tris]          = _world_pipeline_create(e, format, .TRIANGLELIST, true, false)
	set[.Tris_Depth]    = _world_pipeline_create(e, format, .TRIANGLELIST, true, true)
	set[.Tris_Overlay]  = _world_pipeline_create(e, format, .TRIANGLELIST, false, false)
	set[.Tris_Wire]     = _world_pipeline_create(e, format, .TRIANGLELIST, true, false, .LINE)
	set[.Lines]         = _world_pipeline_create(e, format, .LINELIST, true, false)
	set[.Lines_Depth]   = _world_pipeline_create(e, format, .LINELIST, true, true)
	set[.Lines_Overlay] = _world_pipeline_create(e, format, .LINELIST, false, false)
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

// One pipeline of a world shader: its vertex and fragment stages (or caster,
// in a depth-only pass) with the given primitive, depth state, fill and cull.
// `mirrored` makes clockwise triangles the front faces, for a model whose
// transform turns the winding around.
@(private)
_world_pipeline_create :: proc(e: ^_Shader_Entry, format: Target_Format, primitive: sdl.GPUPrimitiveType, depth_test, depth_write: bool, fill := sdl.GPUFillMode.FILL, cull := Cull.None, mirrored := false) -> ^sdl.GPUGraphicsPipeline {
	// Slot 0: the mesh's or the batch's vertices. Slot 1: one _Instance per
	// drawn object, its model matrix as four columns and its tint.
	buffer_descs := [2]sdl.GPUVertexBufferDescription{
		{slot = 0, pitch = size_of(Vertex), input_rate = .VERTEX},
		{slot = 1, pitch = size_of(_Instance), input_rate = .INSTANCE},
	}
	attributes := [11]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, position))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
		{location = 3, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Vertex, color))},
		{location = 4, buffer_slot = 0, format = .FLOAT4, offset = u32(offset_of(Vertex, tangent))},
		{location = 10, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv2))},
		{location = 5, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(_Instance, model))},
		{location = 6, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(_Instance, model)) + 16},
		{location = 7, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(_Instance, model)) + 32},
		{location = 8, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(_Instance, model)) + 48},
		{location = 9, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(_Instance, tint))},
	}
	color_target := sdl.GPUColorTargetDescription{
		format      = target_pixel_format(format),
		blend_state = _ALPHA_BLEND,
	}
	// A depth-only pass has no color target and draws with the shader's
	// caster, or depth.frag when it has none.
	depth_only := format == .Depth
	frag := e.frag
	if depth_only do frag = e.caster != nil ? e.caster : _gfx.depth_frag
	cull_mode: sdl.GPUCullMode
	switch cull {
	case .None:  cull_mode = .NONE
	case .Back:  cull_mode = .BACK
	case .Front: cull_mode = .FRONT
	}
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = e.vert,
		fragment_shader = frag,
		vertex_input_state = {
			vertex_buffer_descriptions = raw_data(buffer_descs[:]),
			num_vertex_buffers         = len(buffer_descs),
			vertex_attributes          = raw_data(attributes[:]),
			num_vertex_attributes      = len(attributes),
		},
		primitive_type = primitive,
		rasterizer_state = {
			fill_mode  = fill,
			cull_mode  = cull_mode,
			front_face = mirrored ? .CLOCKWISE : .COUNTER_CLOCKWISE,
		},
		depth_stencil_state = {
			compare_op         = .LESS_OR_EQUAL,
			enable_depth_test  = depth_test,
			enable_depth_write = depth_write,
		},
		target_info = {
			color_target_descriptions = depth_only ? nil : &color_target,
			num_color_targets         = depth_only ? 0 : 1,
			depth_stencil_format      = _DEPTH_FORMAT,
			has_depth_stencil_target  = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(_gfx.device, info)
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
	e := _Fullscreen_Entry{frag = _create_shader(.FRAGMENT, num_samplers, num_uniform_buffers, frag_spv, frag_msl), samplers = num_samplers}
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
_fullscreen_pipeline :: proc(name: string, format: Target_Format, sky := false) -> ^sdl.GPUGraphicsPipeline {
	e, ok := &_gfx.fullscreen[name]
	if !ok do return nil
	if sky {
		if e.sky[format] == nil do e.sky[format] = _fullscreen_build(e, format, sky = true)
		return e.sky[format]
	}
	if e.pipelines[format] == nil do e.pipelines[format] = _fullscreen_build(e, format)
	return e.pipelines[format]
}

// The pipeline that renders a fullscreen shader into a cubemap face.
_fullscreen_cube_pipeline :: proc(name: string) -> ^sdl.GPUGraphicsPipeline {
	e, ok := &_gfx.fullscreen[name]
	if !ok do return nil
	if e.cube == nil do e.cube = _fullscreen_build(e, .HDR, depth = false)
	return e.cube
}

@(private)
_fullscreen_entry_release :: proc(e: ^_Fullscreen_Entry) {
	for p in e.pipelines {
		if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
	}
	for p in e.sky {
		if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
	}
	if e.cube != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, e.cube)
	if e.frag != nil do sdl.ReleaseGPUShader(_gfx.device, e.frag)
	e^ = {}
}

// Depth is attached but neither tested nor written: every gfx pass has a
// depth target, and the pipeline's target layout has to match the pass's.
@(private)
// The fullscreen triangle lies on the far plane (fullscreen.vert), so a
// `sky` pipeline that tests LESS_OR_EQUAL without writing fills only the
// pixels no earlier draw covered.
_fullscreen_build :: proc(e: ^_Fullscreen_Entry, format: Target_Format, sky := false, depth := true) -> ^sdl.GPUGraphicsPipeline {
	color_target := sdl.GPUColorTargetDescription{format = target_pixel_format(format)}
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = _gfx.fullscreen_vert,
		fragment_shader = e.frag,
		primitive_type  = .TRIANGLELIST,
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets         = 1,
			depth_stencil_format      = _DEPTH_FORMAT,
			has_depth_stencil_target  = depth,
		},
	}
	if sky {
		info.depth_stencil_state = {compare_op = .LESS_OR_EQUAL, enable_depth_test = true}
	}
	return sdl.CreateGPUGraphicsPipeline(_gfx.device, info)
}
