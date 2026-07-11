// GPU device, pipelines, textures, meshes, and the frame lifecycle on
// SDL_GPU. One shader pair serves every pipeline; draws are batched CPU-side
// per pass (see pass.odin).
package gfx

import "base:runtime"
import sdl "vendor:sdl3"

// One vertex format for the CPU batch AND meshes. Normals are unused by the
// unlit shader; reserved for lighting.
Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	color:    [4]u8,
}

Texture :: struct {
	gpu:           ^sdl.GPUTexture,
	width, height: i32,
}

Mesh :: struct {
	vbuf, ibuf:  ^sdl.GPUBuffer,
	index_count: u32,
}

_Pipeline_Kind :: enum u8 {
	Tris,          // alpha-blended, depth test, NO depth write (sprites)
	Tris_Depth,    // opaque, depth test + write (meshes)
	Lines,         // depth-tested lines (grid, selection outline)
	Lines_Overlay, // no depth test (gizmos)
}

_DEPTH_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT

_gfx: struct {
	device:           ^sdl.GPUDevice,
	swapchain_format: sdl.GPUTextureFormat,
	cmd:              ^sdl.GPUCommandBuffer, // valid between frame_begin/frame_end
	pipelines:        [_Pipeline_Kind]^sdl.GPUGraphicsPipeline,
	sampler_linear:   ^sdl.GPUSampler,
	sampler_nearest:  ^sdl.GPUSampler,
	white_tex:        ^Texture,
	window_depth:     ^sdl.GPUTexture, // lazily sized to the swapchain
	window_depth_w:   u32,
	window_depth_h:   u32,
}

// Window + GPU device + pipelines. show=false lets the caller apply saved
// window geometry before show_window().
init :: proc(title: cstring, width, height: i32, show := true) -> bool {
	if !_platform_init(title, width, height, show) do return false

	_gfx.device = sdl.CreateGPUDevice({.SPIRV, .MSL}, ODIN_DEBUG, nil)
	if _gfx.device == nil do return false
	if !sdl.ClaimWindowForGPUDevice(_gfx.device, _platform.window) do return false
	_gfx.swapchain_format = sdl.GetGPUSwapchainTextureFormat(_gfx.device, _platform.window)
	_ = sdl.SetGPUSwapchainParameters(_gfx.device, _platform.window, .SDR, .VSYNC)

	sampler_info := sdl.GPUSamplerCreateInfo{
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_mode    = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	}
	_gfx.sampler_linear = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	sampler_info.min_filter = .NEAREST
	sampler_info.mag_filter = .NEAREST
	sampler_info.mipmap_mode = .NEAREST
	_gfx.sampler_nearest = sdl.CreateGPUSampler(_gfx.device, sampler_info)

	if !_create_pipelines() do return false

	white := [4]u8{255, 255, 255, 255}
	_gfx.white_tex = texture_create(white[:], 1, 1)
	return _gfx.white_tex != nil
}

shutdown :: proc() {
	if _gfx.device != nil {
		_ = sdl.WaitForGPUIdle(_gfx.device)
		_pass_shutdown()
		_debug_text_shutdown()
		if _gfx.white_tex != nil do texture_destroy(_gfx.white_tex)
		if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
		for p in _gfx.pipelines {
			if p != nil do sdl.ReleaseGPUGraphicsPipeline(_gfx.device, p)
		}
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_linear)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_nearest)
		sdl.ReleaseWindowFromGPUDevice(_gfx.device, _platform.window)
		sdl.DestroyGPUDevice(_gfx.device)
	}
	_gfx = {}
	_platform_shutdown()
}

device :: proc() -> ^sdl.GPUDevice {
	return _gfx.device
}

swapchain_format :: proc() -> sdl.GPUTextureFormat {
	return _gfx.swapchain_format
}

frame_begin :: proc() -> bool {
	_platform_frame_tick()
	_gfx.cmd = sdl.AcquireGPUCommandBuffer(_gfx.device)
	return _gfx.cmd != nil
}

frame_end :: proc() {
	if _gfx.cmd != nil {
		_ = sdl.SubmitGPUCommandBuffer(_gfx.cmd)
		_gfx.cmd = nil
	}
}

command_buffer :: proc() -> ^sdl.GPUCommandBuffer {
	return _gfx.cmd
}

_create_pipelines :: proc() -> bool {
	vert := _create_shader(.VERTEX, 0, 1)
	frag := _create_shader(.FRAGMENT, 1, 0)
	if vert == nil || frag == nil do return false
	defer sdl.ReleaseGPUShader(_gfx.device, vert)
	defer sdl.ReleaseGPUShader(_gfx.device, frag)

	buffer_desc := sdl.GPUVertexBufferDescription{
		slot       = 0,
		pitch      = size_of(Vertex),
		input_rate = .VERTEX,
	}
	attributes := [4]sdl.GPUVertexAttribute{
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, position))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
		{location = 3, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Vertex, color))},
	}
	alpha_blend := sdl.GPUColorTargetBlendState{
		src_color_blendfactor = .SRC_ALPHA,
		dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
		color_blend_op        = .ADD,
		src_alpha_blendfactor = .ONE,
		dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
		alpha_blend_op        = .ADD,
		enable_blend          = true,
	}
	color_target := sdl.GPUColorTargetDescription{
		format      = _gfx.swapchain_format,
		blend_state = alpha_blend,
	}

	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader   = vert,
		fragment_shader = frag,
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

	make_pipeline :: proc(info: ^sdl.GPUGraphicsPipelineCreateInfo, primitive: sdl.GPUPrimitiveType, depth_test, depth_write: bool) -> ^sdl.GPUGraphicsPipeline {
		info.primitive_type = primitive
		info.depth_stencil_state = {
			compare_op         = .LESS_OR_EQUAL,
			enable_depth_test  = depth_test,
			enable_depth_write = depth_write,
		}
		return sdl.CreateGPUGraphicsPipeline(_gfx.device, info^)
	}

	_gfx.pipelines[.Tris]          = make_pipeline(&info, .TRIANGLELIST, true, false)
	_gfx.pipelines[.Tris_Depth]    = make_pipeline(&info, .TRIANGLELIST, true, true)
	_gfx.pipelines[.Lines]         = make_pipeline(&info, .LINELIST, true, false)
	_gfx.pipelines[.Lines_Overlay] = make_pipeline(&info, .LINELIST, false, false)
	for p in _gfx.pipelines {
		if p == nil do return false
	}
	return true
}

// Uploads RGBA8 pixels into a new sampled texture. Uses its OWN short-lived
// command buffer so lazy loads mid-frame (between passes) stay legal.
texture_create :: proc(pixels: []u8, width, height: i32) -> ^Texture {
	assert(len(pixels) == int(width * height * 4))
	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = .R8G8B8A8_UNORM,
		usage                = {.SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if gpu_tex == nil do return nil

	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(len(pixels)),
	})
	if transfer == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(pixels), len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy_pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = gpu_tex, w = u32(width), h = u32(height), d = 1},
		false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = width
	tex.height = height
	return tex
}

texture_destroy :: proc(tex: ^Texture) {
	if tex == nil do return
	if tex.gpu != nil do sdl.ReleaseGPUTexture(_gfx.device, tex.gpu)
	free(tex, runtime.default_allocator())
}

// For imgui: since imgui 1.92.2 the SDLGPU3 backend's ImTextureID is the raw
// SDL_GPUTexture pointer (NOT a sampler-binding struct — passing one crashes,
// see the backend's 2025-08-08 breaking change).
texture_imgui_id :: proc(tex: ^Texture) -> rawptr {
	return tex.gpu
}

mesh_create :: proc(vertices: []Vertex, indices: []u32) -> Mesh {
	vsize := u32(len(vertices) * size_of(Vertex))
	isize := u32(len(indices) * size_of(u32))
	vbuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = vsize})
	ibuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.INDEX}, size = isize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = vsize + isize})
	if vbuf == nil || ibuf == nil || transfer == nil {
		if vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, vbuf)
		if ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, ibuf)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(vertices), int(vsize))
	runtime.mem_copy_non_overlapping(rawptr(uintptr(mapped) + uintptr(vsize)), raw_data(indices), int(isize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = vbuf, size = vsize}, false)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer, offset = vsize}, {buffer = ibuf, size = isize}, false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	return Mesh{vbuf = vbuf, ibuf = ibuf, index_count = u32(len(indices))}
}

mesh_destroy :: proc(mesh: ^Mesh) {
	if mesh.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, mesh.vbuf)
	if mesh.ibuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, mesh.ibuf)
	mesh^ = {}
}
