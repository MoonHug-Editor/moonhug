// Render passes and the CPU draw batch. pass_begin_* only records the
// target; pass_end encodes one copy pass (vertex upload) followed by one
// render pass replaying the recorded draws — copy passes can't nest inside
// render passes, and this keeps mid-pass texture_create legal.
package gfx

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
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
	kind:         _Pipeline_Kind,
	is_mesh:      bool,
	fullscreen:   bool, // draw_fullscreen: shader names a fullscreen shader, texture + extra_tex are its inputs
	texture:      ^Texture, // nil = white
	vp_index:     i32,
	first_vertex: u32, // batch draws
	vertex_count: u32,
	mesh:         Mesh, // mesh draws
	mesh_first:   u32, // index range within the mesh (submeshes)
	mesh_count:   u32,
	model:        matrix[4, 4]f32,
	color:        [4]f32,
	shader:       string, // "" = DEFAULT_SHADER (meshes and batched quads)
	material:     []u8,   // fragment UBO slot 1 bytes (shader property block); nil = none
	extra_tex:    []^Texture, // fragment sampler bindings 1..N (multi-texture shaders); nil entries = white
}

// Fragment sampler slots a single draw can bind (mirrors the importer's
// SHADER_MAX_SAMPLERS — pipelines are created with at most this many).
MAX_FRAGMENT_SAMPLERS :: 8

// Must match the GLSL UBO (std140: mat4, mat4, vec4). Batch draws push
// model = identity (vertices are pre-transformed to world space).
_Uniform :: struct {
	view_proj: matrix[4, 4]f32,
	model:     matrix[4, 4]f32,
	tint:      [4]f32,
}

// Up to MAX_LIGHTS lights reach the shader in one UBO. Matches the Light
// component's pool max, so every enabled light in a scene fits.
MAX_LIGHTS :: 8

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
	params:      [4]f32, // x = cos inner half-angle, yzw reserved
}

// Must match the lit shader's LightUBO. cam_pos comes from the draw's view
// (set_view_proj), not set_lights — it's filled in at push time per view
// switch.
_Light_Uniform :: struct {
	ambient_count: [4]f32, // x = ambient floor, y = light count
	cam_pos:       [4]f32, // xyz = camera world position (specular shaders), w unused
	lights:        [MAX_LIGHTS]_Gpu_Light,
	// The shadow map (set_shadow), appended so a shader that declares only the
	// fields above still reads its prefix. shadow_params: x = one texel in uv,
	// y = depth bias, z = 1 when a map is bound, w = the light it belongs to.
	shadow_vp:     matrix[4, 4]f32,
	shadow_params: [4]f32,
}

// The fragment sampler slot the shadow map binds to, for shaders that
// declare it (the surface template's `shadow_map` at set=2, binding=7).
// Material texture rows use bindings 1..SHADOW_SAMPLER_SLOT-1.
SHADOW_SAMPLER_SLOT :: MAX_FRAGMENT_SAMPLERS - 1

_Shadow :: struct {
	has:    bool,    // a map is set for this pass
	tex:    Texture, // the caster pass's depth, by value: set_shadow's argument is a temporary
	vp:     matrix[4, 4]f32,
	params: [4]f32,
}

// Matches the previously baked-in lit shader constants, so scenes without a
// Light component keep looking the same: one white directional, 0.35 ambient.
_LIGHT_DEFAULT :: _Light_Uniform{
	ambient_count = {0.1004, 1, 0, 0}, // 0.35 sRGB in linear
	lights = {
		0 = {
			pos_type    = {0, 0, 0, 0},
			dir_range   = {-0.42107597, -0.84215194, -0.33686078, 0}, // normalize({-0.5,-1,-0.4})
			color_outer = {1, 1, 1, 0},
			params      = {0, 0, 0, 0},
		},
	},
}

// One view entry per set_view_proj call: the matrix plus the camera world
// position fragment shaders see as cam_pos.
_View :: struct {
	vp:      matrix[4, 4]f32,
	cam_pos: [3]f32,
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
	shadow:       _Shadow,               // reset each pass_end
	vps:          [dynamic]_View,
	vtx:          [dynamic]Vertex,
	draws:        [dynamic]_Draw,
	// GPU-side batch storage, grown on demand, reused across passes/frames
	vbuf:          ^sdl.GPUBuffer,
	transfer:      ^sdl.GPUTransferBuffer,
	vbuf_capacity: u32, // in vertices
}

_pass_shutdown :: proc() {
	if _pass.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.vbuf)
	if _pass.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.transfer)
	pool_destroy(&_pass.display_pool)
	delete(_pass.vps)
	delete(_pass.vtx)
	delete(_pass.draws)
	_pass = {}
}

rt_create :: proc(width, height: i32, format := Target_Format.Display) -> ^Render_Target {
	rt := new(Render_Target, runtime.default_allocator())
	rt.width = width
	rt.height = height
	rt.format = format
	rt.color = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = target_pixel_format(format),
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
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
	sdl.ReleaseGPUTexture(_gfx.device, rt.color)
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
pass_begin_target :: proc(rt: ^Render_Target, clear: Maybe([4]f32), keep_depth := false, depth := true) {
	assert(!_pass.active, "gfx pass already active")
	_pass.active = true
	_pass.target_color = rt.color
	_pass.target_depth = rt.depth
	_pass.format = rt.format
	_pass.store_depth = true
	_pass.keep_depth = keep_depth
	_pass.clear = _decode_clear(clear)
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
	if !sdl.WaitAndAcquireGPUSwapchainTexture(_gfx.cmd, _platform.window, &swap_tex, &w, &h) {
		return false
	}
	if swap_tex == nil do return false

	// Remembered for an on-demand capture later this frame (swapchain_capture).
	_swapchain_this_frame = {tex = swap_tex, w = w, h = h}

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

// Directional light for the CURRENT pass's lit-shader draws (one light —
// per-draw light lists are a later problem). Each direction is the way the
// light travels (sun → scene); zero-length falls back to straight down. Not
// calling this keeps the default (one white directional, 0.35 ambient).
set_lights :: proc(ls: []Light, ambient: f32) {
	u := _Light_Uniform{}
	n := min(len(ls), MAX_LIGHTS)
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
		u.lights[i] = _Gpu_Light{
			pos_type    = {l.position.x, l.position.y, l.position.z, f32(l.kind)},
			dir_range   = {d.x, d.y, d.z, max(l.range, 0)},
			color_outer = {srgb_to_linear1(l.color.r) * l.intensity, srgb_to_linear1(l.color.g) * l.intensity, srgb_to_linear1(l.color.b) * l.intensity, l.outer_cos},
			params      = {l.inner_cos, 0, 0, 0},
		}
	}
	_pass.light = u
}

// Back to the built-in default (one white directional, 0.35 ambient) — for
// callers that set temporary lights (the inspector's preview headlight) and
// must not leak them into later passes of lightless scenes.
// The shadow map for the CURRENT pass's lit draws: the depth a caster pass
// rendered from `light_vp` (rt_depth_texture of its target), for light
// `light_index` of set_lights. Shaders that declare the shadow sampler
// (SHADOW_SAMPLER_SLOT) read it, with `bias` in depth units. Not calling this
// leaves every surface lit.
set_shadow :: proc(tex: Texture, light_vp: matrix[4, 4]f32, light_index: int, bias: f32) {
	_pass.shadow = _Shadow{
		has    = true,
		tex    = tex,
		vp     = light_vp,
		params = {1 / f32(max(tex.width, 1)), bias, 1, f32(light_index)},
	}
}

set_lights_default :: proc() {
	_pass.light = _LIGHT_DEFAULT
}

// May change mid-pass (multi-camera stacking, screen-space overlays).
// cam_pos is the camera's world position, exposed to fragment shaders for
// specular terms — screen-space/ortho callers can leave the zero default.
set_view_proj :: proc(vp: matrix[4, 4]f32, cam_pos := [3]f32{0, 0, 0}) {
	v := _View{vp = vp, cam_pos = cam_pos}
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
draw_mesh :: proc(mesh: Mesh, tex: ^Texture, model: matrix[4, 4]f32, color: [4]f32, shader := "", first_index: u32 = 0, index_count: u32 = 0, material: []u8 = nil, extra_tex: []^Texture = nil, wire := false, overlay := false) {
	if mesh.index_count == 0 do return
	count := index_count == 0 ? mesh.index_count : index_count
	if first_index >= mesh.index_count do return
	count = min(count, mesh.index_count - first_index)
	append(&_pass.draws, _Draw{
		kind       = wire ? .Tris_Wire : overlay ? .Tris_Overlay : .Tris_Depth,
		is_mesh    = true,
		texture    = tex,
		vp_index   = _current_vp(),
		mesh       = mesh,
		mesh_first = first_index,
		mesh_count = count,
		model      = model,
		color      = color,
		shader     = shader,
		material   = material,
		extra_tex  = extra_tex,
	})
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
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, &depth_info)
	} else {
		assert(len(_pass.draws) == 0, "gfx draws recorded in a depth-less pass")
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, nil)
	}

	// Light + camera uniforms (fragment slot 0) are re-pushed on view switch —
	// cam_pos is per-view (multi-camera passes). Only pipelines that declare
	// the fragment UBO (lit, user shaders) consume them.
	light := _pass.light.? or_else _LIGHT_DEFAULT
	if _pass.shadow.has {
		light.shadow_vp = _pass.shadow.vp
		light.shadow_params = _pass.shadow.params
	}

	bound: ^sdl.GPUGraphicsPipeline
	batch_bound := false
	pushed_vp := i32(-1)
	pushed_light_vp := i32(-1)
	pushed_mesh := false
	for &d in _pass.draws {
		if pushed_light_vp != d.vp_index {
			light.cam_pos.xyz = _pass.vps[d.vp_index].cam_pos
			sdl.PushGPUFragmentUniformData(_gfx.cmd, 0, &light, size_of(_Light_Uniform))
			pushed_light_vp = d.vp_index
		}
		pipeline := d.fullscreen ? _fullscreen_pipeline(d.shader, _pass.format) : _shader_pipeline(d.shader, _pass.format, d.kind)
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
		if !d.fullscreen && _shader_samplers(d.shader) > SHADOW_SAMPLER_SLOT {
			// The slots between the draw's textures and the shadow slot are
			// bound too (SDL binds a contiguous range), as white.
			for num_bindings < SHADOW_SAMPLER_SLOT {
				bindings[num_bindings] = {texture = _gfx.white_tex.gpu, sampler = smp}
				num_bindings += 1
			}
			shadow_gpu := _pass.shadow.has ? _pass.shadow.tex.gpu : _gfx.white_tex.gpu
			bindings[SHADOW_SAMPLER_SLOT] = {texture = shadow_gpu, sampler = _gfx.sampler_nearest}
			num_bindings = SHADOW_SAMPLER_SLOT + 1
		}
		sdl.BindGPUFragmentSamplers(rp, 0, &bindings[0], num_bindings)

		if d.fullscreen {
			// The property block rides slot 1, as a material's does, so the
			// importer reflects a fullscreen shader's properties the same way.
			if len(d.material) > 0 {
				sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(d.material), u32(len(d.material)))
			}
			sdl.DrawGPUPrimitives(rp, 3, 1, 0, 0)
			// The light UBO push above was for this draw's pipeline, which does
			// not declare it: the next lit draw must push it again.
			pushed_light_vp = -1
			pushed_vp = -1
			batch_bound = false
		} else if d.is_mesh {
			u := _Uniform{view_proj = _pass.vps[d.vp_index].vp, model = d.model, tint = d.color}
			sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
			_push_material(&d)
			pushed_vp = -1
			pushed_mesh = true

			vb := sdl.GPUBufferBinding{buffer = d.mesh.vbuf}
			sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
			sdl.BindGPUIndexBuffer(rp, {buffer = d.mesh.ibuf}, ._32BIT)
			sdl.DrawGPUIndexedPrimitives(rp, d.mesh_count, 1, d.mesh_first, 0, 0)
			batch_bound = false
		} else {
			if pushed_vp != d.vp_index || pushed_mesh {
				u := _Uniform{view_proj = _pass.vps[d.vp_index].vp, model = _MAT4_IDENTITY, tint = {1, 1, 1, 1}}
				sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
				pushed_vp = d.vp_index
				pushed_mesh = false
			}
			_push_material(&d)
			if !batch_bound {
				vb := sdl.GPUBufferBinding{buffer = _pass.vbuf}
				sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
				batch_bound = true
			}
			sdl.DrawGPUPrimitives(rp, d.vertex_count, 1, d.first_vertex, 0)
		}
	}

	if before_end != nil do before_end(_gfx.cmd, rp)
	sdl.EndGPURenderPass(rp)

	clear(&_pass.vtx)
	clear(&_pass.draws)
	clear(&_pass.vps)
	_pass.active = false
	_pass.target_color = nil
	_pass.target_depth = nil
	_pass.light = nil
	_pass.shadow = {}
}

// One copy pass uploading this pass's vertices. cycle=true keeps earlier
// encoded passes (and in-flight frames) reading their own allocation.
_upload_batch :: proc() {
	count := u32(len(_pass.vtx))
	if count == 0 do return

	if count > _pass.vbuf_capacity {
		new_cap := max(u32(4096), _pass.vbuf_capacity)
		for new_cap < count do new_cap *= 2
		if _pass.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, _pass.vbuf)
		if _pass.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, _pass.transfer)
		size := new_cap * size_of(Vertex)
		_pass.vbuf = sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX}, size = size})
		_pass.transfer = sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = size})
		_pass.vbuf_capacity = new_cap
	}

	byte_count := int(count) * size_of(Vertex)
	mapped := sdl.MapGPUTransferBuffer(_gfx.device, _pass.transfer, true)
	runtime.mem_copy_non_overlapping(mapped, raw_data(_pass.vtx), byte_count)
	sdl.UnmapGPUTransferBuffer(_gfx.device, _pass.transfer)

	copy_pass := sdl.BeginGPUCopyPass(_gfx.cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = _pass.transfer},
		{buffer = _pass.vbuf, size = u32(byte_count)}, true)
	sdl.EndGPUCopyPass(copy_pass)
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
