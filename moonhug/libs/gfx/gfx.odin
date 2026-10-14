// GPU device, pipelines, textures, meshes, and the frame lifecycle on
// SDL_GPU. One shader pair serves every pipeline; draws are batched CPU-side
// per pass (see pass.odin).
package gfx

import "core:math"
import "base:runtime"
import sdl "vendor:sdl3"

// One vertex format for the CPU batch AND meshes. Normals are unused by the
// unlit shader; reserved for lighting.
Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	color:    [4]u8,
	// The direction u grows along the surface (xyz) and the bitangent's sign
	// (w, the glTF convention: bitangent = cross(normal, tangent.xyz) * w).
	// What a normal map is decoded against. Zero where there is none (lines,
	// meshes without uvs): shaders fall back to a frame from derivatives.
	tangent:  [4]f32,
}

Texture :: struct {
	gpu:           ^sdl.GPUTexture,
	width, height: i32,
	format:        sdl.GPUTextureFormat, // readback needs the channel order
}

Mesh :: struct {
	vbuf, ibuf:  ^sdl.GPUBuffer,
	index_count: u32,
}

_Pipeline_Kind :: enum u8 {
	Tris,          // alpha-blended, depth test, NO depth write (sprites)
	Tris_Depth,    // opaque, depth test + write (meshes)
	Tris_Overlay,  // alpha-blended, no depth test (gizmo solids, e.g. arrow cones)
	Tris_Wire,     // triangles rasterized as lines, depth test, no write (wireframe view)
	Lines,         // depth-tested lines (selection outline)
	Lines_Depth,   // depth test + WRITE (editor grid — occludes and is occluded
	               // by meshes regardless of draw order; sprites still cover it)
	Lines_Overlay, // no depth test (gizmos)
}

// What a pass renders into. A pipeline is bound to its color target's pixel
// format, so every shader keeps one pipeline set per Target_Format, built the
// first time a pass of that format draws with it (pipelines.odin).
//
// Color is linear everywhere gfx draws: shaders light, blend and filter in
// linear light, and the colors callers pass in (vertex colors, tints, clear
// colors, lights) are sRGB as authored, decoded once on the way in. Only a
// Display target holds sRGB-encoded bytes, because that is what the window
// and imgui show as they are.
Target_Format :: enum u8 {
	// 8-bit sRGB-encoded bytes: the window, the editor's views and previews,
	// anything imgui shows. A pass on one draws into a linear scratch target
	// and pass_end encodes it (display_blit encodes a finished image directly).
	Display,
	HDR, // RGBA16F, linear: the lit scene before tonemapping
	// 8-bit linear, stored as sRGB: the GPU encodes on write and decodes on
	// sampling, so shaders see linear values at 8-bit cost (a tonemapped image,
	// a shadow map's color).
	LDR,
}

DEFAULT_SHADER :: "unlit"

// The fullscreen shader that copies its input to the target.
BLIT_SHADER :: "blit"

// The built-in lit shader's material block (shaders/surface.glsl
// LitMaterial, fragment set 3 binding 1). A lit draw without one gets
// LIT_MATERIAL_DEFAULT, so it never reads the previous draw's.
Lit_Material :: struct {
	params:   [4]f32, // x metallic, y smoothness, z normal scale (0 = no map), w occlusion strength
	emission: [4]f32, // rgb, linear
}

LIT_MATERIAL_DEFAULT :: Lit_Material{params = {0, 0.5, 0, 1}}

// The built-in lit shader's name.
LIT_SHADER :: "lit"

// The fullscreen shader that encodes a linear image to sRGB: what a Display
// target receives (display_blit, and pass_end for a pass on one).
ENCODE_SHADER :: "encode"

// sRGB as authored to linear light, the exact piecewise curve. Alpha stays.
// A color brighter than 1 (an HDR color for emission or bloom) is an sRGB
// color times a linear intensity: its brightest channel is the intensity.
srgb_to_linear :: proc(c: [4]f32) -> [4]f32 {
	m := max(c.r, c.g, c.b, 1)
	return {srgb_to_linear1(c.r / m) * m, srgb_to_linear1(c.g / m) * m, srgb_to_linear1(c.b / m) * m, c.a}
}

// Linear light to sRGB, the inverse of srgb_to_linear (a color above 1 keeps
// its brightest channel as a linear intensity). For linear colors from
// files, such as a glTF material's factors, stored as authored colors.
linear_to_srgb :: proc(c: [4]f32) -> [4]f32 {
	m := max(c.r, c.g, c.b, 1)
	return {linear_to_srgb1(c.r / m) * m, linear_to_srgb1(c.g / m) * m, linear_to_srgb1(c.b / m) * m, c.a}
}

linear_to_srgb1 :: proc(v: f32) -> f32 {
	if v <= 0.0031308 do return max(v, 0) * 12.92
	return 1.055 * math.pow(v, 1 / 2.4) - 0.055
}

srgb_to_linear1 :: proc(v: f32) -> f32 {
	if v <= 0.04045 do return v / 12.92
	return math.pow((v + 0.055) / 1.055, 2.4)
}

// The world shader that draws the world-space normal as color (debug views).
NORMALS_SHADER :: "normals"

_DEPTH_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT

_gfx: struct {
	device:           ^sdl.GPUDevice,
	swapchain_format: sdl.GPUTextureFormat,
	cmd:              ^sdl.GPUCommandBuffer, // valid between frame_begin/frame_end
	shaders:          map[string]_Shader_Entry,     // pipelines.odin, built-ins registered in init
	fullscreen:       map[string]_Fullscreen_Entry, // pipelines.odin
	fullscreen_vert:  ^sdl.GPUShader,              // the fullscreen-triangle vertex stage
	skin_pipeline:    ^sdl.GPUComputePipeline, // skinning.odin
	sampler_linear:   ^sdl.GPUSampler,
	sampler_nearest:  ^sdl.GPUSampler,
	sampler_repeat:   ^sdl.GPUSampler, // linear + REPEAT — mesh draws (glTF's default wrap)
	white_tex:        ^Texture,
	window_depth:     ^sdl.GPUTexture, // lazily sized to the swapchain
	window_depth_w:   u32,
	window_depth_h:   u32,
	// SDL 3.4.14's Metal backend answers QueryGPUFence with the fence's BUSY
	// state (3.4.16 answers signaled). Probed once at init, see _fence_probe.
	fence_query_inverted: bool,
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
	// One frame in flight: the CPU starts a frame once the GPU has finished
	// the last one, so the screen shows input a frame sooner (hover
	// highlights, drags). SDL's default of 2 overlaps CPU and GPU work for
	// throughput, which a light renderer does not need. The swapchain acquire
	// (pass.odin) waits for the GPU instead of dropping the frame.
	if !sdl.SetGPUAllowedFramesInFlight(_gfx.device, 1) do return false
	_fence_probe()

	sampler_info := sdl.GPUSamplerCreateInfo{
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_mode    = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
	}
	_gfx.sampler_linear = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	// Meshes sample with REPEAT — glTF's default wrap mode, and models in the
	// wild rely on it (UVs offset outside [0,1] that wrap back, tiling
	// detail maps). Sprites keep CLAMP so quad edges can't bleed the
	// opposite border under linear filtering.
	sampler_info.address_mode_u = .REPEAT
	sampler_info.address_mode_v = .REPEAT
	sampler_info.address_mode_w = .REPEAT
	_gfx.sampler_repeat = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	sampler_info.address_mode_u = .CLAMP_TO_EDGE
	sampler_info.address_mode_v = .CLAMP_TO_EDGE
	sampler_info.address_mode_w = .CLAMP_TO_EDGE
	sampler_info.min_filter = .NEAREST
	sampler_info.mag_filter = .NEAREST
	sampler_info.mipmap_mode = .NEAREST
	_gfx.sampler_nearest = sdl.CreateGPUSampler(_gfx.device, sampler_info)

	if !_create_pipelines() do return false
	if !_skinning_init() do return false

	white := [4]u8{255, 255, 255, 255}
	_gfx.white_tex = texture_create(white[:], 1, 1)
	return _gfx.white_tex != nil
}

shutdown :: proc() {
	if _gfx.device != nil {
		_ = sdl.WaitForGPUIdle(_gfx.device)
		_pass_shutdown()
		_debug_text_shutdown()
		_skinning_shutdown()
		if _gfx.white_tex != nil do texture_destroy(_gfx.white_tex)
		if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
		_pipelines_shutdown()
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_linear)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_nearest)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_repeat)
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

// Frames begun since startup, bumped before anything else in a frame, so the
// first frame is 1 and a zero stamp never matches a real one. Per-frame work
// that several views would otherwise repeat — skinning, collected once per
// view — stamps itself with this and skips when the stamp already matches.
frame_index: u64

frame_begin :: proc() -> bool {
	frame_index += 1
	_platform_frame_tick()
	_gfx.cmd = sdl.AcquireGPUCommandBuffer(_gfx.device)
	return _gfx.cmd != nil
}

frame_end :: proc() {
	if _gfx.cmd != nil {
		// A pending swapchain capture rides THIS buffer, so it needs the fence
		// this submit produces — the ordinary path takes the cheaper submit.
		if d := _swapchain_take_pending(); d != nil {
			d.fence = sdl.SubmitGPUCommandBufferAndAcquireFence(_gfx.cmd)
		} else {
			_ = sdl.SubmitGPUCommandBuffer(_gfx.cmd)
		}
		_gfx.cmd = nil
	}
	// The swapchain image belongs to this frame only — a capture must not reach
	// for it after submit.
	_swapchain_frame_clear()
}

command_buffer :: proc() -> ^sdl.GPUCommandBuffer {
	return _gfx.cmd
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
	tex.format = .R8G8B8A8_UNORM
	return tex
}

// Overwrites a region of a sampled RGBA8 texture (a dynamic font atlas adding
// a glyph). Own command buffer, like texture_create.
texture_upload_region :: proc(tex: ^Texture, x, y, width, height: i32, pixels: []u8) -> bool {
	if tex == nil || tex.gpu == nil do return false
	assert(len(pixels) == int(width * height * 4))
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = u32(len(pixels))})
	if transfer == nil do return false
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(pixels), len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return false
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy_pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = tex.gpu, x = u32(x), y = u32(y), w = u32(width), h = u32(height), d = 1},
		false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	return true
}

// An in-flight GPU→CPU pixel readback. The copy runs on its own command
// buffer, queued after everything already submitted — poll readiness each
// frame instead of blocking on the fence.
Texture_Download :: struct {
	transfer:      ^sdl.GPUTransferBuffer,
	fence:         ^sdl.GPUFence,
	width, height: i32,
	bgra:          bool,
	// Intermediate texture a swapchain capture copies through, freed with the
	// download. nil for the ordinary render-target path, which reads the RT
	// texture directly.
	scratch_texture: ^sdl.GPUTexture,
}

// Starts an async readback of the texture's pixels. The pass that produced the
// contents must already be SUBMITTED (frame_end) — queue order then guarantees
// the copy sees the finished pixels. Follow with texture_download_ready polls,
// then texture_download_take (or _cancel). nil on failure.
texture_download_begin :: proc(tex: ^Texture) -> ^Texture_Download {
	byte_count := u32(tex.width * tex.height * 4)
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .DOWNLOAD, size = byte_count})
	if transfer == nil do return nil
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return nil
	}
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(copy_pass,
		{texture = tex.gpu, w = u32(tex.width), h = u32(tex.height), d = 1},
		{transfer_buffer = transfer, pixels_per_row = u32(tex.width), rows_per_layer = u32(tex.height)})
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return nil
	}
	d := new(Texture_Download, runtime.default_allocator())
	d.transfer = transfer
	d.fence = fence
	d.width = tex.width
	d.height = tex.height
	d.bgra = tex.format == .B8G8R8A8_UNORM || tex.format == .B8G8R8A8_UNORM_SRGB
	return d
}

texture_download_ready :: proc(d: ^Texture_Download) -> bool {
	// A swapchain capture has no fence until the frame it rides is submitted.
	if d.fence == nil do return false
	return _fence_signaled(d.fence)
}

// A fence that has been waited on is signaled by definition, so a false
// answer from QueryGPUFence means this SDL build reports the inverse.
@(private = "file")
_fence_probe :: proc() {
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil do return
	defer sdl.ReleaseGPUFence(_gfx.device, fence)
	fences := [1]^sdl.GPUFence{fence}
	_ = sdl.WaitForGPUFences(_gfx.device, true, raw_data(fences[:]), 1)
	_gfx.fence_query_inverted = !sdl.QueryGPUFence(_gfx.device, fence)
}

@(private = "file")
_fence_signaled :: proc(fence: ^sdl.GPUFence) -> bool {
	return sdl.QueryGPUFence(_gfx.device, fence) != _gfx.fence_query_inverted
}

// The pixels as RGBA8 rows top-down, allocated with `allocator`. Frees the
// download — call once, after texture_download_ready. nil slice on map failure.
texture_download_take :: proc(d: ^Texture_Download, allocator := context.allocator) -> []u8 {
	defer texture_download_cancel(d)
	// QueryGPUFence only reports that the fence signalled; block until the
	// buffer's contents are actually visible to the host before mapping.
	// Without this the map raced the GPU's writes and the tail of the image
	// came back as untouched memory (alpha 0), a different row count each time.
	if d.fence != nil {
		fences := [1]^sdl.GPUFence{d.fence}
		_ = sdl.WaitForGPUFences(_gfx.device, true, raw_data(fences[:]), 1)
	}
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, d.transfer, false)
	if mapped == nil do return nil
	pixels := make([]u8, int(d.width * d.height * 4), allocator)
	runtime.mem_copy_non_overlapping(raw_data(pixels), mapped, len(pixels))
	sdl.UnmapGPUTransferBuffer(_gfx.device, d.transfer)
	if d.bgra {
		for i := 0; i < len(pixels); i += 4 {
			pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
		}
	}
	return pixels
}

// Frees an in-flight download without taking the pixels (SDL defers the
// actual GPU-side destruction past any pending work).
texture_download_cancel :: proc(d: ^Texture_Download) {
	if d.fence != nil do sdl.ReleaseGPUFence(_gfx.device, d.fence)
	sdl.ReleaseGPUTransferBuffer(_gfx.device, d.transfer)
	if d.scratch_texture != nil do sdl.ReleaseGPUTexture(_gfx.device, d.scratch_texture)
	free(d, runtime.default_allocator())
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
