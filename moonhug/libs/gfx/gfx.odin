// GPU device, pipelines, textures, meshes, and the frame lifecycle on
// SDL_GPU. One shader pair serves every pipeline; draws are batched CPU-side
// per pass (see pass.odin).
package gfx

import "core:math"
import "core:time"
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
	mips:          i32,                  // mip levels, 1 = none below the full size
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

// Which triangles a mesh draw skips (draw_mesh). Front faces wind counter-
// clockwise on screen, as glTF and the built-in meshes author them, or
// clockwise for a mirrored draw.
Cull :: enum u8 {
	None,  // both faces drawn
	Back,  // the usual: the inside of a closed mesh is never seen
	Front, // only the back faces drawn (the inside of a room or a sky dome)
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
	// sampling, so shaders see linear values at 8-bit cost (a tonemapped image).
	LDR,
	// Depth only, no color: a shadow map. A depth-only pass draws with each
	// shader's depth variant: its caster when it has one, else depth.frag
	// (pipelines.odin). pass_begin_target(color = false) makes a depth-only
	// pass on a color target's depth (the depth prepass).
	Depth,
}

DEFAULT_SHADER :: "unlit"

// Depth only, nothing else: what an unclipped mesh draws with in a depth pass,
// whatever its material, so such draws merge by mesh alone.
DEPTH_SHADER :: "depth"

// The fullscreen shader that shows a depth texture as grey (draw_depth_view).
DEPTH_VIEW_SHADER :: "depth_view"

// Temporal anti-aliasing's resolve (shaders/taa.frag.glsl): this frame's
// image, the history, the depth and the motion vectors in, the blended image
// out. Its block is Taa_Params.
TAA_SHADER :: "taa"

Taa_Params :: struct {
	reproject: matrix[4, 4]f32, // this frame's clip space to last frame's, both through the steady camera
	// x = this frame's weight, y = 1 when the history is valid, z = 1 when
	// the motion input holds this frame's motion vectors
	params:    [4]f32,
}

// Screen-space ambient occlusion (shaders/ssao.frag.glsl): the scene's depth
// in, red the open fraction and green the view depth out. Its block is
// Ssao_Params. SSAO_BLUR_SHADER blurs that along one axis, keeping edges,
// and writes blue, the factor for direct light (Ssao_Blur_Params): what
// set_ambient_occlusion takes.
SSAO_SHADER      :: "ssao"
SSAO_BLUR_SHADER :: "ssao_blur"

Ssao_Params :: struct {
	proj:     matrix[4, 4]f32, // the camera's projection, as the depth was drawn
	inv_proj: matrix[4, 4]f32,
	params:   [4]f32,          // x = radius (view units), y = intensity, z = sample count
}

Ssao_Blur_Params :: struct {
	// xy = the step between taps in pixels: {1, 0} then {0, 1}, z = how
	// much of the occlusion also darkens direct light, written to blue
	params: [4]f32,
}

// Screen-space reflections (shaders/ssr.frag.glsl): the scene's depth, the
// world-space normals of the opaque surfaces and last frame's opaque image
// in, premultiplied reflections out: rgb what each pixel's mirror ray sees
// times the confidence, alpha the confidence. Its block is Ssr_Params. What
// set_screen_reflections takes.
SSR_SHADER :: "ssr"

Ssr_Params :: struct {
	proj:      matrix[4, 4]f32, // the camera's projection, as the depth was drawn
	inv_proj:  matrix[4, 4]f32,
	view:      matrix[4, 4]f32, // world to view
	reproject: matrix[4, 4]f32, // this frame's view space to last frame's clip space
	params:    [4]f32,          // x = max distance (view units), y = thickness, z = steps, w = edge fade (fraction of the screen)
	params2:   [4]f32,          // x = 1 when last frame's image is this view's, consecutive and the same size
}

// The sky's block (shaders/skybox.frag.glsl, draw_sky): the view's inverse
// view-projection and the pass's fog (draw_uniform_fog).
Sky_Params :: struct {
	inv_view_proj: matrix[4, 4]f32,
	fog_color:     [4]f32,
	fog_params:    [4]f32,
	fog_more:      [4]f32,
}

// The world shader that draws motion vectors (shaders/motion.frag.glsl): a
// mesh drawn with it writes how far each of its pixels moved on screen since
// the last frame, alpha 1. Its block (draw_mesh material) is Motion_Params.
MOTION_SHADER :: "motion"

Motion_Params :: struct {
	to_prev:        matrix[4, 4]f32, // the object's world space now to last frame's: prev_model * inverse(model)
	view_proj:      matrix[4, 4]f32, // this frame's steady camera
	prev_view_proj: matrix[4, 4]f32, // last frame's steady camera
}

// The fullscreen shader that copies its input to the target.
BLIT_SHADER :: "blit"

// The built-in lit shader's material block (shaders/surface.glsl
// LitMaterial, fragment set 3 binding 1). A lit draw without one gets
// LIT_MATERIAL_DEFAULT, so it never reads the previous draw's.
Lit_Material :: struct {
	params:   [4]f32, // x metallic, y smoothness, z normal scale (0 = no map), w occlusion strength
	emission: [4]f32, // rgb, linear, w = refraction strength
	uv:       [4]f32, // xy the maps' uv scale, zw their offset
	flags:    [4]f32, // x = 1 reads the maps clamped to their edges
}

LIT_MATERIAL_DEFAULT :: Lit_Material{params = {0, 0.5, 0, 1}, uv = {1, 1, 0, 0}}

// The built-in lit shader's name.
LIT_SHADER :: "lit"

// The 1x1 white texture: what an unassigned sampler reads.
white_texture :: proc() -> Texture {
	return _gfx.white_tex^
}

// The image-based light's fullscreen shaders (shaders/env_*.frag): the sky
// into a cube face, a face's GGX prefilter at a roughness, a face's diffuse
// irradiance, and the sky behind a view (draw_sky).
ENV_CAPTURE_SHADER    :: "env_capture"
ENV_PREFILTER_SHADER  :: "env_prefilter"
ENV_IRRADIANCE_SHADER :: "env_irradiance"
SKYBOX_SHADER         :: "skybox"

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
	depth_frag:       ^sdl.GPUShader,              // depth.frag: a depth pass's fragment stage for shaders with no caster
	caster_frag:      ^sdl.GPUShader,              // caster.frag: the Lit and Unlit shaders' caster
	skin_pipeline:    ^sdl.GPUComputePipeline, // skinning.odin
	sampler_linear:   ^sdl.GPUSampler,
	sampler_nearest:  ^sdl.GPUSampler,
	sampler_repeat:   ^sdl.GPUSampler, // linear + REPEAT — mesh draws (glTF's default wrap)
	sampler_shadow:   ^sdl.GPUSampler, // linear depth comparison (LESS_OR_EQUAL: 1 lit), for the shadow maps
	depth_one:        ^sdl.GPUTexture, // 1x1 depth of 1: a shadow map with nothing in it
	white_tex:        ^Texture,
	black_tex:        ^Texture, // the scene colour's stand-in: nothing behind
	clear_tex:        ^Texture, // the screen reflections' stand-in: none (0 confidence)
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

	// max_lod opens every mip level: SDL's zero default clamps each lookup
	// to mip 0, which hides a cubemap's prefiltered mips (textureLod).
	sampler_info := sdl.GPUSamplerCreateInfo{
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_mode    = .LINEAR,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
		max_lod        = 1000,
	}
	_gfx.sampler_linear = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	// Meshes sample with REPEAT — glTF's default wrap mode, and models in the
	// wild rely on it (UVs offset outside [0,1] that wrap back, tiling
	// detail maps). Sprites keep CLAMP so quad edges can't bleed the
	// opposite border under linear filtering.
	sampler_info.address_mode_u = .REPEAT
	sampler_info.address_mode_v = .REPEAT
	sampler_info.address_mode_w = .REPEAT
	// Anisotropic: a surface seen at a grazing angle (a floor toward the
	// horizon) samples along its stretched footprint instead of blurring it.
	sampler_info.enable_anisotropy = true
	sampler_info.max_anisotropy = 8
	_gfx.sampler_repeat = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	sampler_info.enable_anisotropy = false
	sampler_info.max_anisotropy = 0
	sampler_info.address_mode_u = .CLAMP_TO_EDGE
	sampler_info.address_mode_v = .CLAMP_TO_EDGE
	sampler_info.address_mode_w = .CLAMP_TO_EDGE
	sampler_info.min_filter = .NEAREST
	sampler_info.mag_filter = .NEAREST
	sampler_info.mipmap_mode = .NEAREST
	_gfx.sampler_nearest = sdl.CreateGPUSampler(_gfx.device, sampler_info)
	// Shadow maps: each lookup compares a reference depth with the map's
	// texels and filters the results, so one tap is a 2x2 percentage-closer
	// filter. Clamped: the shaders keep taps inside their tile.
	_gfx.sampler_shadow = sdl.CreateGPUSampler(_gfx.device, sdl.GPUSamplerCreateInfo{
		min_filter     = .LINEAR,
		mag_filter     = .LINEAR,
		mipmap_mode    = .NEAREST,
		address_mode_u = .CLAMP_TO_EDGE,
		address_mode_v = .CLAMP_TO_EDGE,
		address_mode_w = .CLAMP_TO_EDGE,
		compare_op     = .LESS_OR_EQUAL,
		enable_compare = true,
	})
	if _gfx.sampler_shadow == nil do return false
	if !_depth_one_init() do return false

	if !_create_pipelines() do return false
	if !_cubemap_init() do return false
	if !_skinning_init() do return false

	white := [4]u8{255, 255, 255, 255}
	_gfx.white_tex = texture_create(white[:], 1, 1)
	black := [4]u8{0, 0, 0, 255}
	_gfx.black_tex = texture_create(black[:], 1, 1)
	clear := [4]u8{0, 0, 0, 0}
	_gfx.clear_tex = texture_create(clear[:], 1, 1)
	return _gfx.white_tex != nil && _gfx.black_tex != nil && _gfx.clear_tex != nil
}

shutdown :: proc() {
	if _gfx.device != nil {
		_ = sdl.WaitForGPUIdle(_gfx.device)
		_pass_shutdown()
		_debug_text_shutdown()
		_skinning_shutdown()
		if _gfx.white_tex != nil do texture_destroy(_gfx.white_tex)
		if _gfx.black_tex != nil do texture_destroy(_gfx.black_tex)
		if _gfx.clear_tex != nil do texture_destroy(_gfx.clear_tex)
		if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
		_cubemap_shutdown()
	_pipelines_shutdown()
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_linear)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_nearest)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_repeat)
		sdl.ReleaseGPUSampler(_gfx.device, _gfx.sampler_shadow)
		if _gfx.depth_one != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.depth_one)
		sdl.ReleaseWindowFromGPUDevice(_gfx.device, _platform.window)
		sdl.DestroyGPUDevice(_gfx.device)
	}
	_gfx = {}
	_platform_shutdown()
}

// The 1x1 depth texture of 1 a pass without a shadow map binds in its place:
// a comparison sampler needs a depth texture, and 1 is the far plane, so
// nothing reads as shadowed. Cleared once by an empty render pass.
@(private = "file")
_depth_one_init :: proc() -> bool {
	_gfx.depth_one = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _DEPTH_FORMAT,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = 1,
		height               = 1,
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if _gfx.depth_one == nil do return false
	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	if cmd == nil do return false
	depth_info := sdl.GPUDepthStencilTargetInfo{
		texture          = _gfx.depth_one,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}
	rp := sdl.BeginGPURenderPass(cmd, nil, 0, &depth_info)
	sdl.EndGPURenderPass(rp)
	return sdl.SubmitGPUCommandBuffer(cmd)
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
	_stats_frame_begin()
	acquire := time.tick_now()
	_gfx.cmd = sdl.AcquireGPUCommandBuffer(_gfx.device)
	_stats_wait(acquire)
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
	_stats_frame_end()
	// The swapchain image belongs to this frame only — a capture must not reach
	// for it after submit.
	_swapchain_frame_clear()
}

command_buffer :: proc() -> ^sdl.GPUCommandBuffer {
	return _gfx.cmd
}

// Uploads RGBA8 pixels into a new sampled texture. Uses its OWN short-lived
// command buffer so lazy loads mid-frame (between passes) stay legal.
//
// `mipmaps` gives it the full chain of mip levels, each half the size of the
// one above, filtered down by the GPU from the uploaded pixels: a texture seen
// small samples the level that matches, instead of one arbitrary texel of
// the full size (shimmer on fine detail, sparkling highlights from normal
// maps). The averaging runs on the stored bytes, so a color texture's levels
// average sRGB-encoded values, slightly darker than averaging light.
texture_create :: proc(pixels: []u8, width, height: i32, mipmaps := false) -> ^Texture {
	assert(len(pixels) == int(width * height * 4))
	return _texture_upload(pixels, width, height, .R8G8B8A8_UNORM, mipmaps)
}

// A linear float texture from RGBA half floats: an HDR image (texture_file.odin).
// Shaders sample it as linear light, it is never sRGB-decoded.
texture_create_hdr :: proc(pixels: [][4]f16, width, height: i32) -> ^Texture {
	assert(len(pixels) == int(width * height))
	return _texture_upload(([^]u8)(raw_data(pixels))[:len(pixels) * size_of([4]f16)], width, height, .R16G16B16A16_FLOAT)
}

// Whether a texture holds linear float data (an HDR image) rather than sRGB
// color bytes.
texture_is_hdr :: proc(tex: ^Texture) -> bool {
	return tex != nil && tex.format == .R16G16B16A16_FLOAT
}

@(private = "file")
_texture_upload :: proc(bytes: []u8, width, height: i32, format: sdl.GPUTextureFormat, mipmaps := false) -> ^Texture {
	// The GPU fills the levels by rendering into them, so a mipmapped texture
	// is a color target too.
	levels := mipmaps ? mip_count(width, height) : 1
	usage: sdl.GPUTextureUsageFlags = {.SAMPLER}
	if levels > 1 do usage += {.COLOR_TARGET}
	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = format,
		usage                = usage,
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = u32(levels),
	})
	if gpu_tex == nil do return nil

	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, sdl.GPUTransferBufferCreateInfo{
		usage = .UPLOAD,
		size  = u32(len(bytes)),
	})
	if transfer == nil {
		sdl.ReleaseGPUTexture(_gfx.device, gpu_tex)
		return nil
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(bytes), len(bytes))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(copy_pass,
		{transfer_buffer = transfer, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = gpu_tex, w = u32(width), h = u32(height), d = 1},
		false)
	sdl.EndGPUCopyPass(copy_pass)
	if levels > 1 do sdl.GenerateMipmapsForGPUTexture(cmd, gpu_tex)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = width
	tex.height = height
	tex.format = format
	tex.mips = levels
	return tex
}

// The levels of a full mip chain for a texture of this size: down to 1x1.
mip_count :: proc(width, height: i32) -> i32 {
	n := i32(1)
	for size := max(width, height); size > 1; size /= 2 do n += 1
	return n
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
	// The levels below follow the new pixels.
	if tex.mips > 1 do sdl.GenerateMipmapsForGPUTexture(cmd, tex.gpu)
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
