// Render passes and the CPU draw batch. pass_begin_* only records the
// target; pass_end encodes one copy pass (vertex upload) followed by one
// render pass replaying the recorded draws — copy passes can't nest inside
// render passes, and this keeps mid-pass texture_create legal.
package gfx

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:time"
import sdl "vendor:sdl3"

// An offscreen color + depth pair. Both are sampleable after the pass that
// filled them: `color` through rt_color_texture, `depth` through
// rt_depth_texture (depth is stored at pass end for render targets, so a later
// pass can read it for post effects).
Render_Target :: struct {
	color, depth:  ^sdl.GPUTexture,
	width, height: i32,
	format:        Target_Format,
}

_Draw :: struct {
	kind:           _Pipeline_Kind,
	is_mesh:        bool,
	fullscreen:     bool, // draw_fullscreen: shader names a fullscreen shader, texture + extra_tex are its inputs
	sky:            bool, // draw_sky: a fullscreen draw on the far plane, depth-tested
	texture:        ^Texture, // nil = white
	vp_index:       i32,
	first_vertex:   u32, // batch draws
	vertex_count:   u32,
	mesh:           Mesh, // mesh draws
	mesh_first:     u32, // index range within the mesh (submeshes)
	mesh_count:     u32,
	instance_first: u32, // mesh draws: the objects drawn, a run of _pass.inst
	instance_count: u32,
	alpha_cutoff:   f32, // the material's alpha clipping threshold, 0 = none (DRAW_UNIFORM_SLOT)
	cull:           Cull, // mesh draws: the faces skipped
	mirrored:       bool, // mesh draws: clockwise triangles are the front faces
	shader:         string, // "" = DEFAULT_SHADER (meshes and batched quads)
	material:     []u8,   // fragment UBO slot 1 bytes (shader property block); nil = none
	extra_tex:    []^Texture, // fragment sampler bindings 1..N (multi-texture shaders); nil entries = white
}

// Fragment sampler slots a single draw can bind (mirrors the importer's
// SHADER_MAX_SAMPLERS — pipelines are created with at most this many).
MAX_FRAGMENT_SAMPLERS :: 12

// Must match the world vertex shader's UBO (std140: mat4).
_Uniform :: struct {
	view_proj: matrix[4, 4]f32,
}

// One drawn object: vertex buffer slot 1 of every world pipeline, read per
// instance (world.vert in_model0..3, in_tint). A mesh draw covers a run of
// these, one per object. Entry 0 of a pass is the identity, which batch draws
// read: their vertices are world-space with colors baked in.
_Instance :: struct {
	model: matrix[4, 4]f32, // column-major, the shader's mat4 columns
	tint:  [4]f32,
}

_INSTANCE_IDENTITY :: _Instance{model = _MAT4_IDENTITY, tint = {1, 1, 1, 1}}

// The fragment uniform slot of the per-draw block (surface.glsl and
// world.frag DrawUBO, set 3 binding 2). A shader that clips declares it.
DRAW_UNIFORM_SLOT :: 2

// Must match DrawUBO: x = the alpha cutoff (a fragment with less alpha is
// discarded, 0 = no clipping), yzw reserved.
_Draw_Uniform :: struct {
	params: [4]f32,
}

// Up to MAX_LIGHTS lights reach the shader, in one uniform block with the
// screen's light tiles (_Cluster_Uniform). Matches the Light component's pool
// max, so every enabled light in a world fits.
MAX_LIGHTS :: 256

// The screen's grid of light tiles: each tile holds a bit per light that
// reaches into it, and a fragment lights with its tile's lights only
// (surface.glsl light_tile). A fixed grid, stretched to the target.
CLUSTER_COLS  :: 16
CLUSTER_ROWS  :: 9
CLUSTER_TILES :: CLUSTER_COLS * CLUSTER_ROWS

// The fragment uniform slot of the light list and tiles (surface.glsl
// ClusterUBO, set 3 binding 3).
LIGHT_LIST_SLOT :: 3

// The first lights again, in the light uniform's documented prefix
// (ambient_count, cam_pos, lights[8]): a hand-written full shader that
// declares only that prefix lights with up to these, every one of them per
// fragment. The surface template reads every light from the light list.
LIGHT_UBO_LIGHTS :: 8

Light_Kind :: enum u32 {
	Directional,
	Point,
	Spot,
}

// One light as the renderer takes it (set_lights). Angles arrive as cosines of
// the HALF angle, so the shader compares dot products directly.
Light :: struct {
	kind:      Light_Kind,
	position:  [3]f32, // point/spot
	direction: [3]f32, // the way the light travels
	color:     [3]f32,
	intensity: f32,
	range:     f32,    // point/spot falloff end
	inner_cos: f32,    // spot: full brightness inside
	outer_cos: f32,    // spot: zero outside
}

// Must match the lit shader's GpuLight (fragment set=3 binding=0), std140:
// four vec4 per light.
_Gpu_Light :: struct {
	pos_type:    [4]f32, // xyz = position, w = kind (0 dir, 1 point, 2 spot)
	dir_range:   [4]f32, // xyz = normalized travel direction, w = range
	color_outer: [4]f32, // rgb premultiplied by intensity, w = cos outer half-angle
	params:      [4]f32, // x = cos inner half-angle, y = first shadow tile, z = shadow tiles (0 none, 1 spot, 6 point), w reserved
}

// The directional light's cascades: at most this many tiles of one atlas.
MAX_CASCADES :: 4

// Spot and point light shadow tiles in one atlas: one per spot light, six per
// point light (cube faces +X -X +Y -Y +Z -Z). Eight point lights' worth: the
// tiles travel in the light uniform, which has room for no more.
MAX_SHADOW_TILES :: 48

// Must match the lit shader's LightUBO. cam_pos comes from the draw's view
// (set_view_proj), not set_lights — it's filled in at push time per view
// switch.
_Light_Uniform :: struct {
	ambient_count:  [4]f32, // x = ambient floor, y = light count
	cam_pos:        [4]f32, // xyz = camera world position (specular shaders), w unused
	lights:         [LIGHT_UBO_LIGHTS]_Gpu_Light, // the first lights, for full shaders
	cluster_params: [4]f32, // x = 1 / target width, y = 1 / target height, the light tiles' scale
	// The directional cascades (set_shadow_cascades). cascade_params: x one
	// texel's world size, y the depth bias in the cascade's depth units.
	// shadow_params: x one atlas texel in uv, y cascade count, z where shadows
	// end, w the light they belong to.
	cascade_vp:     [MAX_CASCADES]matrix[4, 4]f32,
	cascade_rects:  [MAX_CASCADES][4]f32,
	cascade_params: [MAX_CASCADES][4]f32,
	shadow_params:  [4]f32,
	// The environment (set_environment): x diffuse intensity, y specular
	// intensity, z the specular cube's last mip.
	env_params:     [4]f32,
	// Spot and point shadows (set_shadow_atlas): x one atlas texel in uv,
	// y bias along the light ray (world), z the tiles' normal bias (texels),
	// w the cascades' normal bias (texels). tile_params: x near, y far, z one
	// texel's world size at distance 1.
	atlas_params:   [4]f32,
	tile_vp:        [MAX_SHADOW_TILES]matrix[4, 4]f32,
	tile_rects:     [MAX_SHADOW_TILES][4]f32,
	tile_params:    [MAX_SHADOW_TILES][4]f32,
	// Ambient occlusion (set_ambient_occlusion): x how much of it darkens
	// direct light.
	occlusion_params: [4]f32,
}

// The fragment sampler slot the directional cascades' atlas binds to, for
// shaders that declare it (the surface template's `shadow_map` at set=2,
// binding=7), sampled with a depth comparison. Material texture rows use
// bindings 1..SHADOW_SAMPLER_SLOT-1.
SHADOW_SAMPLER_SLOT :: 7
// The environment's prefiltered specular cube and its irradiance cube
// (set_environment), bound like the shadow map to shaders that declare them
// (the surface template). White cubes stand in when no environment is set.
ENV_SPECULAR_SLOT   :: 8
ENV_IRRADIANCE_SLOT :: 9
// The spot and point lights' shadow atlas (the template's `shadow_atlas`),
// sampled like the cascades.
SHADOW_ATLAS_SLOT   :: 10
// The screen's ambient occlusion (set_ambient_occlusion, the template's
// `ambient_occlusion`): red is how much ambient light reaches each pixel.
// White when none is set.
OCCLUSION_SLOT      :: 11

// A screen-space ambient occlusion texture for a pass's lit draws
// (set_ambient_occlusion): `tex` the view's size, red 1 open to 0 occluded,
// `direct` how much of it also darkens direct light (0 none, 1 fully).
Ambient_Occlusion :: struct {
	tex:    Texture,
	direct: f32,
}

_Env :: struct {
	has:        bool,
	specular:   ^Cubemap,
	irradiance: ^Cubemap,
	params:     [4]f32,
}

// The directional light's cascades for a pass (set_shadow_cascades): tiles
// of one depth atlas, each an orthographic view of a slice of the camera's
// frustum.
Shadow_Cascades :: struct {
	tex:         Texture, // the atlas's depth (rt_depth_texture)
	count:       int,     // 0 = no cascades
	light_index: int,     // the light they belong to, in set_lights order
	vp:          [MAX_CASCADES]matrix[4, 4]f32,
	rects:       [MAX_CASCADES][4]f32, // each tile in atlas uv: x, y, width, height
	world_texel: [MAX_CASCADES]f32,    // one texel's world size, for the normal offset
	depth_bias:  [MAX_CASCADES]f32,    // the bias in each cascade's depth units
	normal_bias: f32,                  // texels along the surface normal
	distance:    f32,                  // where shadows end, fading over the last tenth
}

// One spot light's view, or one point light cube face's, in the atlas.
Shadow_Tile :: struct {
	vp:                 matrix[4, 4]f32,
	rect:               [4]f32, // atlas uv: x, y, width, height
	near, far:          f32,    // the perspective's, to turn a biased distance back into depth
	texel_per_distance: f32,    // one texel's world size at distance 1, for the normal offset
}

// Spot and point light shadows for a pass (set_shadow_atlas).
Shadow_Atlas :: struct {
	tex:         Texture,
	tiles:       [MAX_SHADOW_TILES]Shadow_Tile,
	light_tiles: [MAX_LIGHTS][2]i32, // per light in set_lights order: first tile, tile count (0 none)
	bias:        f32,                // world units along the light ray
	normal_bias: f32,                // texels along the surface normal
}

_Shadows :: struct {
	cascades:     Shadow_Cascades,
	has_cascades: bool,
	atlas:        Shadow_Atlas,
	has_atlas:    bool,
}

// Matches the previously baked-in lit shader constants, so scenes without a
// Light component keep looking the same: one white directional, 0.35 ambient.
_LIGHT_DEFAULT :: _Light_Uniform{
	ambient_count = {0.1004, 1, 0, 0}, // 0.35 sRGB in linear
}

_LIGHT_DEFAULT_SUN :: _Gpu_Light{
	pos_type    = {0, 0, 0, 0},
	dir_range   = {-0.42107597, -0.84215194, -0.33686078, 0}, // normalize({-0.5,-1,-0.4})
	color_outer = {1, 1, 1, 0},
	params      = {0, 0, 0, 0},
}

// Must match surface.glsl ClusterUBO (std140): the pass's lights, then two
// uvec4 of light bits per tile (light i at word i / 32, bit i % 32).
_Cluster_Uniform :: struct {
	lights:    [MAX_LIGHTS]_Gpu_Light,
	tile_bits: [CLUSTER_TILES * 2][4]u32,
}

// One view entry per set_view_proj call: the matrix, the camera world
// position fragment shaders see as cam_pos, and the viewport in pixels
// (x, y, width, height, zero = the whole target).
_View :: struct {
	vp:       matrix[4, 4]f32,
	cam_pos:  [3]f32,
	viewport: [4]f32,
}

_pass: struct {
	active:       bool,
	target_color: ^sdl.GPUTexture,
	target_depth: ^sdl.GPUTexture, // nil = depth-less pass (imgui-only)
	format:       Target_Format,   // picks each shader's pipeline set
	store_depth:  bool,            // render targets keep depth for later sampling, the swapchain discards it
	keep_depth:   bool,            // load the target's depth instead of clearing it (pass_begin_target)
	clear:        Maybe([4]f32),   // linear, decoded from the caller's sRGB (raw passes keep it as given)
	// A pass on a Display target draws into a linear scratch target and
	// pass_end encodes the scratch into these (Target_Format).
	display_color: ^sdl.GPUTexture,
	display_depth: ^sdl.GPUTexture,
	scratch:       ^Render_Target,
	encode_src:    Texture, // the scratch's color, alive while pass_end encodes it
	display_pool:  Target_Pool, // scratch targets by size
	light:        Maybe(_Light_Uniform), // nil = _LIGHT_DEFAULT; reset each pass_end
	light_list:   [MAX_LIGHTS]_Gpu_Light, // set_lights's, light_count of them
	light_count:  int,
	shadows:      _Shadows,              // reset each pass_end
	target_w:     f32, // the target's size, what a zero viewport covers
	target_h:     f32,
	env:          _Env,                  // reset each pass_end
	occlusion:    Maybe(Ambient_Occlusion), // reset each pass_end
	vps:          [dynamic]_View,
	vtx:          [dynamic]Vertex,
	inst:         [dynamic]_Instance,
	draws:        [dynamic]_Draw,
	// GPU-side batch and instance storage, grown on demand, reused across
	// passes/frames
	vbuf:          ^sdl.GPUBuffer,
	transfer:      ^sdl.GPUTransferBuffer,
	vbuf_capacity: u32, // in vertices
	inst_buf:      ^sdl.GPUBuffer,
	inst_transfer: ^sdl.GPUTransferBuffer,
	inst_capacity: u32, // in instances
}

_pass_shutdown :: proc() {
	if _pass.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.vbuf)
	if _pass.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.transfer)
	if _pass.inst_buf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.inst_buf)
	if _pass.inst_transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.inst_transfer)
	pool_destroy(&_pass.display_pool)
	delete(_pass.vps)
	delete(_pass.vtx)
	delete(_pass.inst)
	delete(_pass.draws)
	_pass = {}
}

rt_create :: proc(width, height: i32, format := Target_Format.Display) -> ^Render_Target {
	rt := new(Render_Target, runtime.default_allocator())
	rt.width = width
	rt.height = height
	rt.format = format
	if format != .Depth {
		rt.color = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
			type                 = .D2,
			format               = target_pixel_format(format),
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = u32(width),
			height               = u32(height),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
	}
	rt.depth = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _DEPTH_FORMAT,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	return rt
}

// No-op when the size is unchanged. Callers must re-fetch rt_imgui_id after
// a resize (the color texture is recreated) — fetching it every frame is the
// normal pattern.
rt_resize :: proc(rt: ^Render_Target, width, height: i32) {
	if rt.width == width && rt.height == height do return
	if rt.color != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.color)
	sdl.ReleaseGPUTexture(_gfx.device, rt.depth)
	tmp := rt_create(width, height, rt.format)
	rt.color = tmp.color
	rt.depth = tmp.depth
	rt.width = width
	rt.height = height
	free(tmp, runtime.default_allocator())
}

// The target's color as a sampleable texture, for draw_fullscreen inputs
// and draw_quad. Non-owning: valid until the target is resized or destroyed,
// and only reads what passes BEFORE the current one wrote.
rt_color_texture :: proc(rt: ^Render_Target) -> Texture {
	assert(rt.format != .Depth, "a Depth target has no color: read rt_depth_texture")
	return Texture{gpu = rt.color, width = rt.width, height = rt.height, format = target_pixel_format(rt.format)}
}

// The target's depth as a sampleable texture (D32, read the red channel).
// Same lifetime rules as rt_color_texture.
rt_depth_texture :: proc(rt: ^Render_Target) -> Texture {
	return Texture{gpu = rt.depth, width = rt.width, height = rt.height, format = _DEPTH_FORMAT}
}

rt_destroy :: proc(rt: ^Render_Target) {
	if rt == nil do return
	if rt.color != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.color)
	if rt.depth != nil do sdl.ReleaseGPUTexture(_gfx.device, rt.depth)
	free(rt, runtime.default_allocator())
}

// imgui 1.92.2+ SDLGPU3 convention: ImTextureID = raw ^sdl.GPUTexture.
rt_imgui_id :: proc(rt: ^Render_Target) -> rawptr {
	return rt.color
}

// Copies the RT's color into a new standalone sampled texture the caller owns
// (texture_destroy frees it). The blit records on the FRAME command buffer, so
// call it between passes, after the pass that filled the RT — ordering within
// the frame makes the copy valid for any later sampling, imgui included.
rt_snapshot :: proc(rt: ^Render_Target) -> ^Texture {
	assert(!_pass.active, "rt_snapshot must run between passes")
	if _gfx.cmd == nil do return nil
	gpu_tex := sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = target_pixel_format(rt.format),
		usage                = {.SAMPLER, .COLOR_TARGET},
		width                = u32(rt.width),
		height               = u32(rt.height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	if gpu_tex == nil do return nil
	sdl.BlitGPUTexture(_gfx.cmd, sdl.GPUBlitInfo{
		source      = {texture = rt.color, w = u32(rt.width), h = u32(rt.height)},
		destination = {texture = gpu_tex, w = u32(rt.width), h = u32(rt.height)},
		load_op     = .DONT_CARE,
		filter      = .LINEAR,
	})
	tex := new(Texture, runtime.default_allocator())
	tex.gpu = gpu_tex
	tex.width = rt.width
	tex.height = rt.height
	tex.format = target_pixel_format(rt.format)
	return tex
}

// Copies `src`'s color into `dst`'s, scaled to `dst`'s size with linear
// filtering (a thumbnail, or a full-size copy). Both formats must be the same
// kind (LDR to LDR, HDR to HDR). Recorded on the frame command buffer between
// passes, so it reads what the passes before it drew.
rt_copy :: proc(dst, src: ^Render_Target) {
	assert(!_pass.active, "rt_copy must run between passes")
	assert(dst.format != .Depth && src.format != .Depth, "rt_copy copies color: a Depth target has none")
	if _gfx.cmd == nil || dst == nil || src == nil do return
	sdl.BlitGPUTexture(_gfx.cmd, sdl.GPUBlitInfo{
		source      = {texture = src.color, w = u32(src.width), h = u32(src.height)},
		destination = {texture = dst.color, w = u32(dst.width), h = u32(dst.height)},
		load_op     = .DONT_CARE,
		filter      = .LINEAR,
	})
}

// Async readback of the RT's color contents (texture_download_* protocol).
// The contents must come from an already SUBMITTED frame — calling this at
// the top of a frame reads what the previous frame drew.
rt_download_begin :: proc(rt: ^Render_Target) -> ^Texture_Download {
	assert(rt.format == .Display, "rt_download_begin reads Display targets only (8-bit, the bytes the window shows)")
	tex := rt_color_texture(rt)
	return texture_download_begin(&tex)
}

// The swapchain image this frame is drawing into, and its size. Valid between
// pass_begin_swapchain and frame_end. nil outside that window, or on a frame the
// acquire failed (minimized window).
//
// Its size is what a full-window capture renders the UI at (swapchain_size).
@(private = "file")
_swapchain_this_frame: struct {
	tex:  ^sdl.GPUTexture,
	w, h: u32,
}

// The window image's size this frame, false outside pass_begin_swapchain and
// frame_end or on a frame the acquire failed (minimized window).
swapchain_size :: proc() -> (w, h: i32, ok: bool) {
	if _swapchain_this_frame.tex == nil do return 0, 0, false
	return i32(_swapchain_this_frame.w), i32(_swapchain_this_frame.h), true
}

// Starts a readback of a render target as this frame's passes leave it: a
// download encoded into the FRAME's command buffer, behind those passes, and
// fenced by frame_end's submit. texture_download_begin would acquire its own
// buffer and submit at once, ahead of passes still sitting unsubmitted in the
// frame buffer, and read an untouched texture.
//
// The window's own image cannot be read on every backend (Metal makes it
// framebuffer-only), so a full-window picture is the UI drawn a second time
// into a Display target, then read with this (the editor's screenshot).
// Call while the frame's command buffer is open, after the passes that drew
// the target. The caller keeps the target alive until the download is taken.
frame_capture_begin :: proc(rt: ^Render_Target) -> ^Texture_Download {
	if _gfx.cmd == nil || rt == nil do return nil
	w, h := u32(rt.width), u32(rt.height)
	if w < 2 || h < 2 do return nil
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .DOWNLOAD, size = w * h * 4})
	if transfer == nil do return nil
	copy_pass := sdl.BeginGPUCopyPass(_gfx.cmd)
	if copy_pass == nil {
		sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return nil
	}
	sdl.DownloadFromGPUTexture(copy_pass,
		{texture = rt.color, w = w, h = h, d = 1},
		{transfer_buffer = transfer, pixels_per_row = w, rows_per_layer = h})
	sdl.EndGPUCopyPass(copy_pass)

	format := target_pixel_format(rt.format)
	d := new(Texture_Download, runtime.default_allocator())
	d.transfer = transfer
	d.fence = nil // set by frame_end
	d.width = i32(w)
	d.height = i32(h)
	d.bgra = format == .B8G8R8A8_UNORM || format == .B8G8R8A8_UNORM_SRGB
	_swapchain_pending_download = d
	return d
}

// A capture riding this frame's command buffer, waiting for the submit in
// frame_end to give it a fence.
@(private = "file")
_swapchain_pending_download: ^Texture_Download

// Begins a pass on a render target. `clear` (sRGB, as authored) nil keeps
// the color the target holds. `keep_depth` keeps its depth too, so several
// passes draw into one scene with one depth buffer (a render pipeline's
// scene passes). Depth is otherwise cleared: a pass that starts a new scene.
//
// On a Display target the pass draws into a linear scratch target of the
// same size, and pass_end encodes it into the target: everything drawn is
// lit and blended in linear light. Such a pass starts from a clear color and
// fresh depth, since the target's own bytes are encoded. display_blit puts a
// finished linear image on a Display target without the scratch.
//
// `depth` false makes a depth-less pass that draws the target's bytes as
// given, for external pipelines without a depth attachment (imgui drawing
// the editor's UI into a capture target). gfx's own draws need depth.
//
// `color` false makes a depth-only pass on the target's depth (the depth
// prepass on a scene target), as every pass on a Depth target is: no color
// attachment, `clear` ignored, each draw through its shader's depth variant
// (Target_Format.Depth).
//
// `shared_depth` draws into `rt`'s color against another target's depth, of
// the same size, kept as it is: the motion vectors of moved objects, hidden
// where the scene drew something nearer.
pass_begin_target :: proc(rt: ^Render_Target, clear: Maybe([4]f32), keep_depth := false, depth := true, color := true, shared_depth: ^Render_Target = nil) {
	assert(!_pass.active, "gfx pass already active")
	_pass.active = true
	_pass.target_color = rt.color
	_pass.target_depth = rt.depth
	keep_depth := keep_depth
	if shared_depth != nil {
		assert(shared_depth.width == rt.width && shared_depth.height == rt.height, "gfx: a shared depth is the target's size")
		assert(rt.format != .Display && rt.format != .Depth && color && depth, "gfx: a shared depth is for a color pass with depth")
		_pass.target_depth = shared_depth.depth
		keep_depth = true
	}
	_pass.target_w, _pass.target_h = f32(rt.width), f32(rt.height)
	_pass.format = rt.format
	_pass.store_depth = true
	_pass.keep_depth = keep_depth
	_pass.clear = _decode_clear(clear)
	if rt.format == .Depth || !color {
		assert(depth, "a depth-only pass draws into the depth")
		assert(rt.format != .Display, "a Display target's depth is the scratch's: no depth-only pass on it")
		_pass.target_color = nil
		_pass.format = .Depth
		_pass.clear = nil
		return
	}
	if !depth {
		_pass.target_depth = nil
		_pass.store_depth = false
		_pass.keep_depth = false
		_pass.clear = clear
		return
	}
	if rt.format == .Display {
		assert(clear != nil && !keep_depth, "a pass on a Display target starts from a clear color and fresh depth")
		_redirect(rt.color, rt.depth, rt.width, rt.height)
	}
}

// Puts a finished linear image (`src`, any format) on a Display target,
// encoded to sRGB: what a render pipeline's last pass does. `dst` nil is the
// window. False when the window is minimized.
display_blit :: proc(dst: ^Render_Target, src: Texture) -> bool {
	assert(!_pass.active, "gfx pass already active")
	if dst == nil {
		if !pass_begin_swapchain(nil, raw = true) do return false
	} else {
		assert(dst.format == .Display, "display_blit draws on Display targets")
		_pass.active = true
		_pass.target_color = dst.color
		_pass.target_depth = dst.depth
		_pass.target_w, _pass.target_h = f32(dst.width), f32(dst.height)
		_pass.format = .Display
		_pass.store_depth = true
		_pass.keep_depth = false
		_pass.clear = nil
	}
	_pass.encode_src = src
	draw_fullscreen(ENCODE_SHADER, []^Texture{&_pass.encode_src})
	pass_end()
	return true
}

// The scratch target a Display pass draws into, sized to it.
@(private = "file")
_redirect :: proc(color, depth: ^sdl.GPUTexture, w, h: i32) {
	b: [32]u8
	key := fmt.bprintf(b[:], "%dx%d", w, h)
	scratch := pool_target(&_pass.display_pool, key, w, h, .HDR)
	_pass.display_color = color
	_pass.display_depth = depth
	_pass.scratch = scratch
	_pass.target_color = scratch.color
	_pass.target_depth = scratch.depth
	_pass.format = .HDR
}

@(private = "file")
_decode_clear :: proc(clear: Maybe([4]f32)) -> Maybe([4]f32) {
	c, ok := clear.?
	if !ok do return nil
	return srgb_to_linear(c)
}

// Acquires the swapchain image; false when the window is minimized (skip
// drawing this frame). The window depth buffer is lazily (re)sized.
// depth=false makes a depth-less pass — REQUIRED when only external
// pipelines without a depth attachment draw in it (the editor's imgui pass);
// our own gfx pipelines must NOT draw in such a pass (they declare D32).
// The window is a Display target: a pass with depth draws into a linear
// scratch encoded at pass_end, as pass_begin_target does. A depth-less pass
// and a `raw` one draw the window's bytes as given (imgui, display_blit).
pass_begin_swapchain :: proc(clear: Maybe([4]f32), depth := true, raw := false) -> bool {
	assert(!_pass.active, "gfx pass already active")
	swap_tex: ^sdl.GPUTexture
	w, h: u32
	acquire := time.tick_now()
	acquired := sdl.WaitAndAcquireGPUSwapchainTexture(_gfx.cmd, _platform.window, &swap_tex, &w, &h)
	_stats_wait(acquire)
	if !acquired do return false
	if swap_tex == nil do return false

	// Remembered for an on-demand capture later this frame (swapchain_capture).
	_swapchain_this_frame = {tex = swap_tex, w = w, h = h}
	_pass.target_w, _pass.target_h = f32(w), f32(h)

	if !depth {
		_pass.active = true
		_pass.target_color = swap_tex
		_pass.target_depth = nil
		_pass.format = .Display
		_pass.store_depth = false
		_pass.keep_depth = false
		_pass.clear = clear
		return true
	}

	if _gfx.window_depth == nil || _gfx.window_depth_w != w || _gfx.window_depth_h != h {
		if _gfx.window_depth != nil do sdl.ReleaseGPUTexture(_gfx.device, _gfx.window_depth)
		_gfx.window_depth = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
			type                 = .D2,
			format               = _DEPTH_FORMAT,
			usage                = {.DEPTH_STENCIL_TARGET},
			width                = w,
			height               = h,
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
		_gfx.window_depth_w = w
		_gfx.window_depth_h = h
	}

	_pass.active = true
	_pass.target_color = swap_tex
	_pass.target_depth = _gfx.window_depth
	_pass.format = .Display
	_pass.store_depth = false
	_pass.keep_depth = false
	_pass.clear = clear
	if !raw {
		assert(clear != nil, "a pass on the window starts from a clear color (display_blit puts a finished image there)")
		_pass.clear = _decode_clear(clear)
		_redirect(swap_tex, _gfx.window_depth, i32(w), i32(h))
	}
	return true
}

// The lights for the CURRENT pass's lit-shader draws, up to MAX_LIGHTS. gfx
// bins them into the screen's light tiles per view, so a fragment lights with
// those that reach its tile only. Each direction is the way the light travels
// (sun → scene); zero-length falls back to straight down. Not calling this
// keeps the default (one white directional, 0.35 ambient).
set_lights :: proc(ls: []Light, ambient: f32) {
	assert(len(ls) <= MAX_LIGHTS, "set_lights: more lights than MAX_LIGHTS")
	u := _Light_Uniform{}
	n := len(ls)
	// Colors and the ambient level are sRGB as authored, lit in linear.
	u.ambient_count = {srgb_to_linear1(clamp(ambient, 0, 1)), f32(n), 0, 0}
	for i in 0 ..< n {
		l := ls[i]
		d := l.direction
		len_sq := d.x * d.x + d.y * d.y + d.z * d.z
		if len_sq < 1e-12 {
			d = {0, -1, 0}
		} else {
			d /= math.sqrt(len_sq)
		}
		_pass.light_list[i] = _Gpu_Light{
			pos_type    = {l.position.x, l.position.y, l.position.z, f32(l.kind)},
			dir_range   = {d.x, d.y, d.z, max(l.range, 0)},
			color_outer = {srgb_to_linear1(l.color.r) * l.intensity, srgb_to_linear1(l.color.g) * l.intensity, srgb_to_linear1(l.color.b) * l.intensity, l.outer_cos},
			params      = {l.inner_cos, 0, 0, 0},
		}
	}
	_pass.light = u
	_pass.light_count = n
}

// The image-based light for the CURRENT pass's lit draws: `specular`, a
// cube whose mips are prefiltered for rising roughness, and `irradiance`,
// its cosine-convolved diffuse light, scaled by the two intensities. Not
// calling this keeps the ambient level as a uniform white environment.
set_environment :: proc(specular, irradiance: ^Cubemap, diffuse_intensity, specular_intensity: f32) {
	if specular == nil || irradiance == nil do return
	_pass.env = _Env{
		has        = true,
		specular   = specular,
		irradiance = irradiance,
		params     = {diffuse_intensity, specular_intensity, f32(specular.mips - 1), 0},
	}
}

// Back to the built-in default (one white directional, 0.35 ambient) — for
// callers that set temporary lights (the inspector's preview headlight) and
// must not leak them into later passes of lightless scenes.
// The directional light's cascades for the CURRENT pass's lit draws (the
// shadow_cascades render step's result). Shaders that declare the cascades'
// sampler (SHADOW_SAMPLER_SLOT) read it. Not calling this leaves every
// surface lit by that light.
set_shadow_cascades :: proc(c: Shadow_Cascades) {
	_pass.shadows.cascades = c
	_pass.shadows.has_cascades = c.count > 0
}

// The screen's ambient occlusion for the CURRENT pass's lit draws (the
// engine's scene_ssao step), read at OCCLUSION_SLOT: it shades the
// environment's light, and `direct` of the lights'. Not calling this leaves
// every surface open.
set_ambient_occlusion :: proc(ao: Ambient_Occlusion) {
	_pass.occlusion = ao
}

// The spot and point lights' shadow atlas for the CURRENT pass's lit draws
// (the shadow_atlas render step's result), read at SHADOW_ATLAS_SLOT.
set_shadow_atlas :: proc(a: ^Shadow_Atlas) {
	_pass.shadows.atlas = a^
	_pass.shadows.has_atlas = true
}

set_lights_default :: proc() {
	_pass.light = nil
	_pass.light_count = 0
}

// May change mid-pass (multi-camera stacking, screen-space overlays).
// cam_pos is the camera's world position, exposed to fragment shaders for
// specular terms — screen-space/ortho callers can leave the zero default.
//
// `viewport` (x, y, width, height in pixels, origin top-left) confines the
// draws that follow to a part of the target: one tile of a shadow atlas.
// Zero is the whole target.
set_view_proj :: proc(vp: matrix[4, 4]f32, cam_pos := [3]f32{0, 0, 0}, viewport := [4]f32{}) {
	v := _View{vp = vp, cam_pos = cam_pos, viewport = viewport}
	if len(_pass.vps) > 0 && _pass.vps[len(_pass.vps)-1] == v do return
	append(&_pass.vps, v)
}

_MAT4_IDENTITY :: matrix[4, 4]f32{
	1, 0, 0, 0,
	0, 1, 0, 0,
	0, 0, 1, 0,
	0, 0, 0, 1,
}

_current_vp :: proc() -> i32 {
	if len(_pass.vps) == 0 {
		append(&_pass.vps, _View{vp = _MAT4_IDENTITY})
	}
	return i32(len(_pass.vps) - 1)
}

// corners in draw order: bottom-left, bottom-right, top-right, top-left
// (two CCW triangles). tex=nil draws untextured white. shader/material work
// like draw_mesh's (sprite materials); normal is the quad's facing, consumed
// by lighting shaders. Same-state consecutive quads merge into one draw —
// distinct material slices don't merge (compared by pointer). depth_test=false
// draws over everything (gizmo icons).
draw_quad :: proc(corners: [4][3]f32, uvs: [4][2]f32, color: [4]f32, tex: ^Texture, shader := "", material: []u8 = nil, normal := [3]f32{0, 0, 1}, extra_tex: []^Texture = nil, depth_test := true) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := normal
	// u runs along the bottom edge, v up the left one: the tangent is the
	// bottom edge's direction, flipped when the uvs are mirrored.
	t := _quad_tangent(corners, uvs, n)
	append(&_pass.vtx,
		Vertex{corners[0], n, uvs[0], c, t},
		Vertex{corners[1], n, uvs[1], c, t},
		Vertex{corners[2], n, uvs[2], c, t},
		Vertex{corners[0], n, uvs[0], c, t},
		Vertex{corners[2], n, uvs[2], c, t},
		Vertex{corners[3], n, uvs[3], c, t},
	)
	_batch_append(.Tris if depth_test else .Tris_Overlay, tex, first, 6, shader, material, extra_tex)
}

// A quad's tangent from its corners and uvs (bl, br, tr, tl): the bottom
// edge's direction, with w the sign that makes cross(normal, tangent) * w
// run the way v grows.
@(private = "file")
_quad_tangent :: proc(corners: [4][3]f32, uvs: [4][2]f32, n: [3]f32) -> [4]f32 {
	e1 := corners[1] - corners[0]
	e2 := corners[3] - corners[0]
	du1, dv1 := uvs[1].x - uvs[0].x, uvs[1].y - uvs[0].y
	du2, dv2 := uvs[3].x - uvs[0].x, uvs[3].y - uvs[0].y
	det := du1 * dv2 - du2 * dv1
	if abs(det) < 1e-12 do return {}
	r := 1 / det
	t := (e1 * dv2 - e2 * dv1) * r
	b := (e2 * du1 - e1 * du2) * r
	tl := linalg.length(t)
	if tl < 1e-12 do return {}
	t /= tl
	w: f32 = linalg.dot(linalg.cross(n, t), b) < 0 ? -1 : 1
	return {t.x, t.y, t.z, w}
}

// Untextured filled triangle (white 1x1 texture bound at draw). Winding is
// irrelevant — the pipelines don't cull.
draw_triangle :: proc(a, b, c: [3]f32, color: [4]f32, depth_test := true) {
	col := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	append(&_pass.vtx, Vertex{a, n, {}, col, {}}, Vertex{b, n, {}, col, {}}, Vertex{c, n, {}, col, {}})
	_batch_append(depth_test ? .Tris : .Tris_Overlay, nil, first, 3)
}

// depth_write=true makes the line participate in occlusion both ways (editor
// grid): later depth-tested draws can't paint over closer line pixels.
draw_line :: proc(a, b: [3]f32, color: [4]f32, depth_test := true, depth_write := false) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	kind: _Pipeline_Kind = depth_test ? (depth_write ? .Lines_Depth : .Lines) : .Lines_Overlay
	append(&_pass.vtx, Vertex{a, n, {}, c, {}}, Vertex{b, n, {}, c, {}})
	_batch_append(kind, nil, first, 2)
}

// shader picks a registered shader set (shader_register); ""/unknown names
// fall back to DEFAULT_SHADER. The caller keeps `shader` alive through
// pass_end (material cache / string literals — never temp per-frame builds);
// `material` (property-block UBO bytes for fragment slot 1) may be
// temp-allocated — it's read at pass_end within the same frame.
// index_count=0 draws the whole mesh; a submesh passes its index range.
// wire draws the triangles as lines (wireframe view) with depth test, no write.
// overlay draws alpha-blended with no depth test or write (the overdraw view).
//
// Instancing: a draw that matches the previous one in everything but `model`
// and `color` (same mesh and index range, texture, shader, material bytes,
// extra textures, cutoff, cull, mirroring, view and kind) joins it as one more instance, so N copies
// of a mesh drawn in a row cost one draw call. Callers order their draws to
// make such runs (engine render_execute sorts by material and mesh).
//
// alpha_cutoff is the material's alpha clipping threshold: a shader that
// clips (the surface template, the unlit shader, their casters) discards a
// fragment whose alpha is below it. 0 clips nothing.
//
// cull skips the back or the front faces. `mirrored` is for a model whose
// transform turns the triangles' winding around (negative determinant): its
// clockwise triangles are the front faces, so culling and the shader's
// gl_FrontFacing still see the outside as the front. Wire and overlay draws
// show both faces and ignore both.
draw_mesh :: proc(mesh: Mesh, tex: ^Texture, model: matrix[4, 4]f32, color: [4]f32, shader := "", first_index: u32 = 0, index_count: u32 = 0, material: []u8 = nil, extra_tex: []^Texture = nil, wire := false, overlay := false, alpha_cutoff: f32 = 0, cull := Cull.None, mirrored := false) {
	if mesh.index_count == 0 do return
	count := index_count == 0 ? mesh.index_count : index_count
	if first_index >= mesh.index_count do return
	count = min(count, mesh.index_count - first_index)
	kind: _Pipeline_Kind = wire ? .Tris_Wire : overlay ? .Tris_Overlay : .Tris_Depth
	cull := kind == .Tris_Depth ? cull : .None
	mirrored := kind == .Tris_Depth && mirrored
	vp := _current_vp()
	_instance_base()
	inst := u32(len(_pass.inst))
	append(&_pass.inst, _Instance{model = model, tint = color})

	if n := len(_pass.draws); n > 0 {
		last := &_pass.draws[n - 1]
		if last.is_mesh && last.kind == kind && last.mesh == mesh &&
		   last.mesh_first == first_index && last.mesh_count == count &&
		   last.texture == tex && last.vp_index == vp && last.shader == shader && last.alpha_cutoff == alpha_cutoff && last.cull == cull && last.mirrored == mirrored &&
		   slice.equal(last.material, material) && slice.equal(last.extra_tex, extra_tex) &&
		   last.instance_first + last.instance_count == inst {
			last.instance_count += 1
			return
		}
	}
	append(&_pass.draws, _Draw{
		kind           = kind,
		is_mesh        = true,
		texture        = tex,
		vp_index       = vp,
		mesh           = mesh,
		mesh_first     = first_index,
		mesh_count     = count,
		instance_first = inst,
		instance_count = 1,
		alpha_cutoff   = alpha_cutoff,
		cull           = cull,
		mirrored       = mirrored,
		shader         = shader,
		material       = material,
		extra_tex      = extra_tex,
	})
}

// Entry 0 of the pass's instances: the identity batch draws read.
@(private = "file")
_instance_base :: proc() {
	if len(_pass.inst) == 0 do append(&_pass.inst, _INSTANCE_IDENTITY)
}

// Runs a fullscreen shader (fullscreen_register) over the whole target:
// a blit, a tonemap, a post effect. `inputs` bind as the shader's samplers
// 0..N (an input is usually rt_color_texture or rt_depth_texture of a target
// an EARLIER pass filled, never the current pass's own target), `material`
// is its property block (fragment UBO set=3 binding=1, slot 1). Draws in order with everything
// else in the pass, so a blit then a mesh draw layers the mesh over the blit.
draw_fullscreen :: proc(shader: string, inputs: []^Texture, material: []u8 = nil) {
	if len(inputs) == 0 do return
	append(&_pass.draws, _Draw{
		fullscreen = true,
		texture    = inputs[0],
		vp_index   = _current_vp(),
		shader     = shader,
		material   = material,
		extra_tex  = inputs[1:],
	})
}

// A fullscreen shader drawn behind everything the pass drew so far: on the
// far plane, depth-tested without writing, so it fills only uncovered
// pixels (the sky, after the opaque meshes).
draw_sky :: proc(shader: string, inputs: []^Texture, material: []u8 = nil) {
	draw_fullscreen(shader, inputs, material)
	_pass.draws[len(_pass.draws) - 1].sky = true
}

// A depth texture (rt_depth_texture) as grey over the whole target, near
// white and far black, for showing a depth target: `perspective` spreads a
// perspective camera's depth, which bunches near 1, an orthographic one
// (a shadow map) reads as it is.
draw_depth_view :: proc(depth: Texture, perspective: bool) {
	tex := new_clone(depth, context.temp_allocator) // read at pass_end
	mode := new_clone([4]f32{perspective ? 1 : 0, 0, 0, 0}, context.temp_allocator)
	draw_fullscreen(DEPTH_VIEW_SHADER, []^Texture{tex}, (^[16]u8)(mode)[:])
}

_color_u8 :: proc(c: [4]f32) -> [4]u8 {
	return {
		u8(clamp(c.r, 0, 1) * 255),
		u8(clamp(c.g, 0, 1) * 255),
		u8(clamp(c.b, 0, 1) * 255),
		u8(clamp(c.a, 0, 1) * 255),
	}
}

// Extends the previous draw when pipeline/texture/view/shader/material
// match — the common case for sprite runs and grid lines. Material slices
// compare by pointer: callers reuse one packed slice per material to merge.
_batch_append :: proc(kind: _Pipeline_Kind, tex: ^Texture, first: u32, count: u32, shader := "", material: []u8 = nil, extra_tex: []^Texture = nil) {
	vp := _current_vp()
	_instance_base()
	if len(_pass.draws) > 0 {
		last := &_pass.draws[len(_pass.draws)-1]
		if !last.is_mesh && last.kind == kind && last.texture == tex && last.vp_index == vp &&
		   last.shader == shader &&
		   raw_data(last.material) == raw_data(material) && len(last.material) == len(material) &&
		   raw_data(last.extra_tex) == raw_data(extra_tex) && len(last.extra_tex) == len(extra_tex) &&
		   last.first_vertex + last.vertex_count == first {
			last.vertex_count += count
			return
		}
	}
	append(&_pass.draws, _Draw{
		kind         = kind,
		texture      = tex,
		vp_index     = vp,
		first_vertex = first,
		vertex_count = count,
		shader       = shader,
		material     = material,
		extra_tex    = extra_tex,
	})
}

// Encodes the pass: batch upload (copy pass), then the render pass replaying
// draws. before_end runs inside the render pass (the editor renders imgui
// draw data there).
pass_end :: proc(before_end: proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) = nil) {
	assert(_pass.active, "gfx pass not active")
	display_color, display_depth, scratch := _pass.display_color, _pass.display_depth, _pass.scratch
	_pass.display_color, _pass.display_depth, _pass.scratch = nil, nil, nil
	_pass_flush(before_end)
	if display_color == nil do return

	// A Display pass: encode the linear scratch into the real target.
	_pass.active = true
	_pass.target_color = display_color
	_pass.target_depth = display_depth
	_pass.format = .Display
	_pass.store_depth = false
	_pass.keep_depth = false
	_pass.clear = [4]f32{0, 0, 0, 0}
	_pass.encode_src = rt_color_texture(scratch)
	draw_fullscreen(ENCODE_SHADER, []^Texture{&_pass.encode_src})
	_pass_flush(nil)
}

// A draw's material block (fragment slot 1): its own, or the lit shader's
// default for a lit draw that brought none.
@(private = "file")
_push_material :: proc(d: ^_Draw) {
	if len(d.material) > 0 {
		sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(d.material), u32(len(d.material)))
	} else if d.shader == LIT_SHADER {
		block := LIT_MATERIAL_DEFAULT
		sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, &block, size_of(block))
	}
}

// The pass's cascades and atlas into the light uniform, and each shadowed
// spot or point light's tiles into its GpuLight (when the pass lights).
@(private = "file")
_apply_shadows :: proc(light: ^_Light_Uniform, cluster: ^_Cluster_Uniform) {
	if _pass.shadows.has_cascades {
		c := &_pass.shadows.cascades
		n := min(c.count, MAX_CASCADES)
		for i in 0 ..< n {
			light.cascade_vp[i] = c.vp[i]
			light.cascade_rects[i] = c.rects[i]
			light.cascade_params[i] = {c.world_texel[i], c.depth_bias[i], 0, 0}
		}
		light.shadow_params = {1 / f32(max(c.tex.width, 1)), f32(n), c.distance, f32(c.light_index)}
		light.atlas_params.w = c.normal_bias
	}
	if _pass.shadows.has_atlas {
		a := &_pass.shadows.atlas
		light.atlas_params.x = 1 / f32(max(a.tex.width, 1))
		light.atlas_params.y = a.bias
		light.atlas_params.z = a.normal_bias
		for t, i in a.tiles {
			light.tile_vp[i] = t.vp
			light.tile_rects[i] = t.rect
			light.tile_params[i] = {t.near, t.far, t.texel_per_distance, 0}
		}
		if cluster != nil {
			for lt, i in a.light_tiles {
				cluster.lights[i].params.y = f32(lt[0])
				cluster.lights[i].params.z = f32(lt[1])
			}
		}
	}
}

// Sets each light's bit in the tiles of the screen it reaches, seen through
// view `v` (its matrix and viewport on the pass's target): a point or spot
// light's range sphere, inside the view's frustum, over the screen rectangle
// of its bounding box (the whole screen once the box reaches behind the
// camera), a directional light everywhere.
@(private = "file")
_cluster_bin :: proc(c: ^_Cluster_Uniform, count: int, v: _View) {
	c.tile_bits = {}
	rect := v.viewport == {} ? [4]f32{0, 0, _pass.target_w, _pass.target_h} : v.viewport
	tw, th := max(_pass.target_w, 1), max(_pass.target_h, 1)
	planes := _frustum_planes(v.vp)
	for i in 0 ..< count {
		l := &c.lights[i]
		x0, y0, x1, y1 := 0, 0, CLUSTER_COLS - 1, CLUSTER_ROWS - 1
		if l.pos_type.w >= 0.5 {
			centre := l.pos_type.xyz
			r := l.dir_range.w
			outside := false
			for p in planes {
				if p.x * centre.x + p.y * centre.y + p.z * centre.z + p.w < -r {
					outside = true
					break
				}
			}
			if outside do continue
			lo := [2]f32{max(f32), max(f32)}
			hi := [2]f32{-max(f32), -max(f32)}
			behind := false
			for k in 0 ..< 8 {
				corner := [4]f32{
					centre.x + (k & 1 == 0 ? -r : r),
					centre.y + (k & 2 == 0 ? -r : r),
					centre.z + (k & 4 == 0 ? -r : r),
					1,
				}
				clip := v.vp * corner
				if clip.w <= 1e-4 {
					behind = true
					break
				}
				ndc := clip.xy / clip.w
				lo = {min(lo.x, ndc.x), min(lo.y, ndc.y)}
				hi = {max(hi.x, ndc.x), max(hi.y, ndc.y)}
			}
			if !behind {
				// NDC to target pixels (y down), then to tiles.
				px0 := rect[0] + (lo.x * 0.5 + 0.5) * rect[2]
				px1 := rect[0] + (hi.x * 0.5 + 0.5) * rect[2]
				py0 := rect[1] + (0.5 - hi.y * 0.5) * rect[3]
				py1 := rect[1] + (0.5 - lo.y * 0.5) * rect[3]
				x0 = clamp(int(px0 / tw * CLUSTER_COLS), 0, CLUSTER_COLS - 1)
				x1 = clamp(int(px1 / tw * CLUSTER_COLS), 0, CLUSTER_COLS - 1)
				y0 = clamp(int(py0 / th * CLUSTER_ROWS), 0, CLUSTER_ROWS - 1)
				y1 = clamp(int(py1 / th * CLUSTER_ROWS), 0, CLUSTER_ROWS - 1)
			}
		}
		word, bit := i / 32, u32(1) << u32(i % 32)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				t := y * CLUSTER_COLS + x
				c.tile_bits[t * 2 + word / 4][word % 4] |= bit
			}
		}
	}
}

// A view-projection's six clip planes, normalized, (normal, d) with
// dot(normal, p) + d >= 0 inside. The near plane is the -1 <= z/w one,
// conservative for gfx's 0 <= z/w projections.
@(private = "file")
_frustum_planes :: proc(vp: matrix[4, 4]f32) -> (planes: [6][4]f32) {
	row :: proc(m: matrix[4, 4]f32, i: int) -> [4]f32 {
		return {m[i, 0], m[i, 1], m[i, 2], m[i, 3]}
	}
	r0, r1, r2, r3 := row(vp, 0), row(vp, 1), row(vp, 2), row(vp, 3)
	planes = {r3 + r0, r3 - r0, r3 + r1, r3 - r1, r3 + r2, r3 - r2}
	for &p in planes {
		l := math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
		if l > 0 do p /= l
	}
	return
}

// Encodes the pass's render pass from its recorded draws and resets it.
@(private = "file")
_pass_flush :: proc(before_end: proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass)) {
	_upload_batch()

	color_info := sdl.GPUColorTargetInfo{
		texture  = _pass.target_color,
		load_op  = .LOAD,
		store_op = .STORE,
	}
	if clear, ok := _pass.clear.?; ok {
		color_info.load_op = .CLEAR
		color_info.clear_color = {clear.r, clear.g, clear.b, clear.a}
	}
	// A depth-only pass (Target_Format.Depth) has no color attachment.
	colors: ^sdl.GPUColorTargetInfo = _pass.target_color != nil ? &color_info : nil
	num_colors := u32(_pass.target_color != nil ? 1 : 0)
	rp: ^sdl.GPURenderPass
	if _pass.target_depth != nil {
		depth_info := sdl.GPUDepthStencilTargetInfo{
			texture          = _pass.target_depth,
			clear_depth      = 1,
			load_op          = _pass.keep_depth ? .LOAD : .CLEAR,
			store_op         = _pass.store_depth ? .STORE : .DONT_CARE,
			stencil_load_op  = .DONT_CARE,
			stencil_store_op = .DONT_CARE,
		}
		rp = sdl.BeginGPURenderPass(_gfx.cmd, colors, num_colors, &depth_info)
	} else {
		assert(len(_pass.draws) == 0, "gfx draws recorded in a depth-less pass")
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, nil)
	}
	_stats_pass()

	// Light + camera uniforms (fragment slot 0) are re-pushed on view switch —
	// cam_pos is per-view (multi-camera passes). Only pipelines that declare
	// the fragment UBO (lit, user shaders) consume them.
	light := _pass.light.? or_else _LIGHT_DEFAULT
	// The light list, for a pass that lights (a depth pass does not): the
	// tiles are binned per view as the draws reach it.
	cluster: ^_Cluster_Uniform
	light_count := 0
	if _pass.format != .Depth {
		cluster = new(_Cluster_Uniform, context.temp_allocator)
		if _pass.light != nil {
			light_count = _pass.light_count
			copy(cluster.lights[:light_count], _pass.light_list[:light_count])
		} else {
			light_count = 1
			cluster.lights[0] = _LIGHT_DEFAULT_SUN
		}
		light.ambient_count.y = f32(light_count)
		light.cluster_params = {1 / max(_pass.target_w, 1), 1 / max(_pass.target_h, 1), 0, 0}
	}
	_apply_shadows(&light, cluster)
	if cluster != nil {
		head := min(light_count, LIGHT_UBO_LIGHTS)
		copy(light.lights[:head], cluster.lights[:head])
	}
	// Without an environment the white cubes times the ambient level light
	// what no light reaches, uniformly.
	env_specular, env_irradiance := _pass.env.specular, _pass.env.irradiance
	if _pass.env.has {
		light.env_params = _pass.env.params
	} else {
		env_specular, env_irradiance = _cubemap_white(), _cubemap_white()
		light.env_params = {light.ambient_count.x, light.ambient_count.x, 0, 0}
	}
	occlusion_gpu := _gfx.white_tex.gpu
	if ao, has := _pass.occlusion.?; has {
		occlusion_gpu = ao.tex.gpu
		light.occlusion_params = {clamp(ao.direct, 0, 1), 0, 0, 0}
	}

	bound: ^sdl.GPUGraphicsPipeline
	batch_bound := false
	pushed_vp := i32(-1)
	pushed_light_vp := i32(-1)
	pushed_cutoff := f32(-1)
	viewport := [4]f32{} // the render pass starts on the whole target
	for &d in _pass.draws {
		if want := _pass.vps[d.vp_index].viewport; want != viewport {
			r := want == {} ? [4]f32{0, 0, _pass.target_w, _pass.target_h} : want
			sdl.SetGPUViewport(rp, {x = r[0], y = r[1], w = r[2], h = r[3], min_depth = 0, max_depth = 1})
			viewport = want
		}
		// A depth pass's DEPTH_SHADER draws read no light uniform (depth.frag).
		if pushed_light_vp != d.vp_index && !(_pass.format == .Depth && d.shader == DEPTH_SHADER) {
			light.cam_pos.xyz = _pass.vps[d.vp_index].cam_pos
			sdl.PushGPUFragmentUniformData(_gfx.cmd, 0, &light, size_of(_Light_Uniform))
			if cluster != nil {
				_cluster_bin(cluster, light_count, _pass.vps[d.vp_index])
				sdl.PushGPUFragmentUniformData(_gfx.cmd, LIGHT_LIST_SLOT, cluster, size_of(_Cluster_Uniform))
			}
			pushed_light_vp = d.vp_index
		}
		pipeline := d.fullscreen ? _fullscreen_pipeline(d.shader, _pass.format, d.sky) : _shader_pipeline(d.shader, _pass.format, d.kind, d.cull, d.mirrored)
		if pipeline == nil do continue
		if pipeline != bound {
			sdl.BindGPUGraphicsPipeline(rp, pipeline)
			bound = pipeline
			batch_bound = false // vertex buffer binding survives, but re-bind cheaply per pipeline switch
		}
		tex := d.texture != nil ? d.texture : _gfx.white_tex
		// Meshes wrap (glTF default REPEAT — UVs may live outside [0,1]);
		// batch quads clamp (sprite edges must not bleed the opposite border).
		smp := d.is_mesh ? _gfx.sampler_repeat : _gfx.sampler_linear
		// Slot 0 = main texture; extra_tex fills 1..N (sized by the caller to
		// the shader's declared sampler count, nil entries bind white).
		bindings: [MAX_FRAGMENT_SAMPLERS]sdl.GPUTextureSamplerBinding
		bindings[0] = {texture = tex.gpu, sampler = smp}
		num_bindings := u32(1)
		for et in d.extra_tex {
			if num_bindings >= MAX_FRAGMENT_SAMPLERS do break
			t := et != nil ? et : _gfx.white_tex
			bindings[num_bindings] = {texture = t.gpu, sampler = smp}
			num_bindings += 1
		}
		// A shader that declares the shadow slot gets the pass's shadow map
		// there (white, depth 1, when none is set: every surface lit). Nearest
		// filtering: the PCF taps compare depths, a blend of two depths is
		// neither.
		if !d.fullscreen && _shader_samplers(d.shader, _pass.format) > SHADOW_SAMPLER_SLOT {
			// The slots between the draw's textures and the shadow slot are
			// bound too (SDL binds a contiguous range), as white.
			for num_bindings < SHADOW_SAMPLER_SLOT {
				bindings[num_bindings] = {texture = _gfx.white_tex.gpu, sampler = smp}
				num_bindings += 1
			}
			shadow_gpu := _pass.shadows.has_cascades ? _pass.shadows.cascades.tex.gpu : _gfx.depth_one
			bindings[SHADOW_SAMPLER_SLOT] = {texture = shadow_gpu, sampler = _gfx.sampler_shadow}
			num_bindings = SHADOW_SAMPLER_SLOT + 1
		}
		if !d.fullscreen && _shader_samplers(d.shader, _pass.format) > ENV_IRRADIANCE_SLOT && env_specular != nil && env_irradiance != nil {
			bindings[ENV_SPECULAR_SLOT] = {texture = env_specular.tex, sampler = _gfx.sampler_linear}
			bindings[ENV_IRRADIANCE_SLOT] = {texture = env_irradiance.tex, sampler = _gfx.sampler_linear}
			num_bindings = ENV_IRRADIANCE_SLOT + 1
		}
		if !d.fullscreen && _shader_samplers(d.shader, _pass.format) > SHADOW_ATLAS_SLOT {
			atlas_gpu := _pass.shadows.has_atlas ? _pass.shadows.atlas.tex.gpu : _gfx.depth_one
			bindings[SHADOW_ATLAS_SLOT] = {texture = atlas_gpu, sampler = _gfx.sampler_shadow}
			num_bindings = SHADOW_ATLAS_SLOT + 1
		}
		if !d.fullscreen && _shader_samplers(d.shader, _pass.format) > OCCLUSION_SLOT {
			bindings[OCCLUSION_SLOT] = {texture = occlusion_gpu, sampler = _gfx.sampler_linear}
			num_bindings = OCCLUSION_SLOT + 1
		}
		sdl.BindGPUFragmentSamplers(rp, 0, &bindings[0], num_bindings)
		if !d.fullscreen && pushed_cutoff != d.alpha_cutoff {
			u := _Draw_Uniform{params = {d.alpha_cutoff, 0, 0, 0}}
			sdl.PushGPUFragmentUniformData(_gfx.cmd, DRAW_UNIFORM_SLOT, &u, size_of(_Draw_Uniform))
			pushed_cutoff = d.alpha_cutoff
		}

		if d.fullscreen {
			// The property block rides slot 1, as a material's does, so the
			// importer reflects a fullscreen shader's properties the same way.
			if len(d.material) > 0 {
				sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(d.material), u32(len(d.material)))
			}
			sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
			_stats_draw(1, 1)
			// The light UBO push above was for this draw's pipeline, which does
			// not declare it: the next lit draw must push it again.
			pushed_light_vp = -1
			pushed_vp = -1
			pushed_cutoff = -1
			batch_bound = false
		} else if d.is_mesh {
			if pushed_vp != d.vp_index {
				u := _Uniform{view_proj = _pass.vps[d.vp_index].vp}
				sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
				pushed_vp = d.vp_index
			}
			_push_material(&d)

			// The draw's run of instances, bound at its offset.
			vbs := [2]sdl.GPUBufferBinding{
				{buffer = d.mesh.vbuf},
				{buffer = _pass.inst_buf, offset = d.instance_first * size_of(_Instance)},
			}
			sdl.BindGPUVertexBuffers(rp, 0, &vbs[0], 2)
			sdl.BindGPUIndexBuffer(rp, {buffer = d.mesh.ibuf}, ._32BIT)
			sdl.DrawGPUIndexedPrimitives(rp, d.mesh_count, d.instance_count, d.mesh_first, 0, 0)
			_stats_draw(int(d.instance_count), int(d.mesh_count / 3))
			batch_bound = false
		} else {
			if pushed_vp != d.vp_index {
				u := _Uniform{view_proj = _pass.vps[d.vp_index].vp}
				sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
				pushed_vp = d.vp_index
			}
			_push_material(&d)
			if !batch_bound {
				// Instance 0, the identity: batch vertices are world-space.
				vbs := [2]sdl.GPUBufferBinding{{buffer = _pass.vbuf}, {buffer = _pass.inst_buf}}
				sdl.BindGPUVertexBuffers(rp, 0, &vbs[0], 2)
				batch_bound = true
			}
			sdl.DrawGPUPrimitives(rp, d.vertex_count, 1, d.first_vertex, 0)
			_stats_draw(1, d.kind <= .Tris_Wire ? int(d.vertex_count / 3) : 0)
		}
	}

	if before_end != nil do before_end(_gfx.cmd, rp)
	sdl.EndGPURenderPass(rp)

	clear(&_pass.vtx)
	clear(&_pass.inst)
	clear(&_pass.draws)
	clear(&_pass.vps)
	_pass.active = false
	_pass.target_color = nil
	_pass.target_depth = nil
	_pass.light = nil
	_pass.shadows = {}
	_pass.env = {}
	_pass.occlusion = nil
}

// One copy pass uploading this pass's batch vertices and instances.
// cycle=true keeps earlier encoded passes (and in-flight frames) reading their
// own allocation.
_upload_batch :: proc() {
	vtx_count := u32(len(_pass.vtx))
	inst_count := u32(len(_pass.inst))
	if vtx_count == 0 && inst_count == 0 do return

	copy_pass := sdl.BeginGPUCopyPass(_gfx.cmd)
	if vtx_count > 0 {
		_upload_grow(&_pass.vbuf, &_pass.transfer, &_pass.vbuf_capacity, vtx_count, size_of(Vertex), 4096)
		_upload(copy_pass, _pass.vbuf, _pass.transfer, raw_data(_pass.vtx), int(vtx_count) * size_of(Vertex))
	}
	if inst_count > 0 {
		_upload_grow(&_pass.inst_buf, &_pass.inst_transfer, &_pass.inst_capacity, inst_count, size_of(_Instance), 1024)
		_upload(copy_pass, _pass.inst_buf, _pass.inst_transfer, raw_data(_pass.inst), int(inst_count) * size_of(_Instance))
	}
	sdl.EndGPUCopyPass(copy_pass)
}

// A vertex buffer and its upload buffer holding at least `count` elements,
// doubled from `minimum` and recreated when too small.
@(private = "file")
_upload_grow :: proc(buf: ^^sdl.GPUBuffer, transfer: ^^sdl.GPUTransferBuffer, capacity: ^u32, count, stride, minimum: u32) {
	if count <= capacity^ do return
	new_cap := max(minimum, capacity^)
	for new_cap < count do new_cap *= 2
	if buf^ != nil do sdl.ReleaseGPUBuffer(_gfx.device, buf^)
	if transfer^ != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer^)
	size := new_cap * stride
	buf^ = sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = size})
	transfer^ = sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = size})
	capacity^ = new_cap
}

@(private = "file")
_upload :: proc(copy_pass: ^sdl.GPUCopyPass, buf: ^sdl.GPUBuffer, transfer: ^sdl.GPUTransferBuffer, data: rawptr, byte_count: int) {
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, true)
	runtime.mem_copy_non_overlapping(mapped, data, byte_count)
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = buf, size = u32(byte_count)}, true)
}

// Frame teardown: the swapchain image is only valid until submit.
_swapchain_frame_clear :: proc() {
	_swapchain_this_frame = {}
}

// Hands the frame's pending capture to frame_end, which submits with a fence.
_swapchain_take_pending :: proc() -> ^Texture_Download {
	d := _swapchain_pending_download
	_swapchain_pending_download = nil
	return d
}
