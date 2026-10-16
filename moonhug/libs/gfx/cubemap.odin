package gfx

// Cubemaps: six square faces, sampled by direction (samplerCube). The image-
// based light lives in them (set_environment): an environment rendered face
// by face with a fullscreen shader (cubemap_render), its mips filled by the
// GPU (cubemap_generate_mips) or rendered one by one (a prefiltered
// specular cube, roughness rising with the mip).
//
// Face order is the APIs' own: +X, -X, +Y, -Y, +Z, -Z. A fullscreen shader
// rendering face f reads its direction from frag_uv, (0, 0) at the face's
// top-left: shaders/env_common.glsl face_dir.

import "base:runtime"
import sdl "vendor:sdl3"

Cubemap :: struct {
	tex:  ^sdl.GPUTexture,
	size: i32, // one face's width and height at mip 0
	mips: i32,
}

// An RGBA16F cubemap of `size` with `mips` levels, renderable and sampleable.
cubemap_create :: proc(size, mips: i32) -> ^Cubemap {
	c := new(Cubemap, runtime.default_allocator())
	c.size = size
	c.mips = max(mips, 1)
	c.tex = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .CUBE,
		format               = .R16G16B16A16_FLOAT,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(size),
		height               = u32(size),
		layer_count_or_depth = 6,
		num_levels           = u32(c.mips),
	})
	if c.tex == nil {
		free(c, runtime.default_allocator())
		return nil
	}
	return c
}

cubemap_destroy :: proc(c: ^Cubemap) {
	if c == nil do return
	if c.tex != nil do sdl.ReleaseGPUTexture(_gfx.device, c.tex)
	free(c, runtime.default_allocator())
}

// The cube as an input of a fullscreen shader (draw_fullscreen, draw_sky,
// cubemap_render): the shader declares it as a samplerCube.
cubemap_texture :: proc(c: ^Cubemap) -> Texture {
	return Texture{gpu = c.tex, width = c.size, height = c.size, format = .R16G16B16A16_FLOAT}
}

// Renders one face (0..5) at one mip with a fullscreen shader: its own
// render pass on the frame's command buffer, no depth. `inputs` bind at
// samplers 0..N, `params` is the shader's property block (slot 1). Call
// between passes.
cubemap_render :: proc(c: ^Cubemap, face, mip: i32, shader: string, inputs: []Texture, params: []u8) {
	assert(!_pass.active, "cubemap_render must run between passes")
	if _gfx.cmd == nil || c == nil do return
	pipeline := _fullscreen_cube_pipeline(shader)
	if pipeline == nil do return
	color := sdl.GPUColorTargetInfo{
		texture              = c.tex,
		mip_level            = u32(mip),
		layer_or_depth_plane = u32(face),
		load_op              = .DONT_CARE,
		store_op             = .STORE,
	}
	rp := sdl.BeginGPURenderPass(_gfx.cmd, &color, 1, nil)
	_stats_pass()
	sdl.BindGPUGraphicsPipeline(rp, pipeline)
	bindings: [4]sdl.GPUTextureSamplerBinding
	n := min(len(inputs), len(bindings))
	for i in 0 ..< n do bindings[i] = {texture = inputs[i].gpu, sampler = _gfx.sampler_linear}
	if n > 0 do sdl.BindGPUFragmentSamplers(rp, 0, &bindings[0], u32(n))
	if len(params) > 0 do sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(params), u32(len(params)))
	sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
	_stats_draw(1, 1)
	sdl.EndGPURenderPass(rp)
}

// Copies a render target's colour (HDR) onto one face at mip 0, scaled to
// the face, mirrored left to right when `flip`: a face rendered through a
// camera looking out from the cube's centre comes out mirrored against the
// cube's convention (the faces are laid out as seen from outside), so a
// capture flips every face. Call between passes.
cubemap_blit_face :: proc(c: ^Cubemap, face: i32, src: ^Render_Target, flip := true) {
	assert(!_pass.active, "cubemap_blit_face must run between passes")
	if _gfx.cmd == nil || c == nil || src == nil do return
	sdl.BlitGPUTexture(_gfx.cmd, sdl.GPUBlitInfo{
		source      = {texture = src.color, w = u32(src.width), h = u32(src.height)},
		destination = {texture = c.tex, layer_or_depth_plane = u32(face), w = u32(c.size), h = u32(c.size)},
		load_op     = .DONT_CARE,
		filter      = .LINEAR,
		flip_mode   = flip ? .HORIZONTAL : .NONE,
	})
}

// Fills mips 1.. from mip 0 with the GPU's filter. Call between passes.
cubemap_generate_mips :: proc(c: ^Cubemap) {
	assert(!_pass.active, "cubemap_generate_mips must run between passes")
	if _gfx.cmd == nil || c == nil || c.mips < 2 do return
	sdl.GenerateMipmapsForGPUTexture(_gfx.cmd, c.tex)
}

// A 1x1 white cube: the environment of a pass that sets none (the ambient
// level, uniform from every direction). Uploaded once at init.
@(private = "file")
_white_cube: ^sdl.GPUTexture

@(private = "file")
_white_cubemap: Cubemap

_cubemap_white :: proc() -> ^Cubemap {
	return &_white_cubemap
}

_cubemap_init :: proc() -> bool {
	_white_cube = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .CUBE,
		format               = .R8G8B8A8_UNORM,
		usage                = {.SAMPLER},
		width                = 1,
		height               = 1,
		layer_count_or_depth = 6,
		num_levels           = 1,
	})
	if _white_cube == nil do return false
	_white_cubemap = Cubemap{tex = _white_cube, size = 1, mips = 1}

	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = 4})
	if transfer == nil do return false
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
	mapped := ([^]u8)(sdl.MapGPUTransferBuffer(_gfx.device, transfer, false))
	if mapped == nil do return false
	mapped[0], mapped[1], mapped[2], mapped[3] = 255, 255, 255, 255
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return false
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	for face in 0 ..< u32(6) {
		sdl.UploadToGPUTexture(copy_pass,
			{transfer_buffer = transfer, pixels_per_row = 1, rows_per_layer = 1},
			{texture = _white_cube, layer = face, w = 1, h = 1, d = 1}, false)
	}
	sdl.EndGPUCopyPass(copy_pass)
	return sdl.SubmitGPUCommandBuffer(cmd)
}

_cubemap_shutdown :: proc() {
	if _white_cube != nil do sdl.ReleaseGPUTexture(_gfx.device, _white_cube)
	_white_cube = nil
	_white_cubemap = {}
}
