// Render passes and the CPU draw batch. pass_begin_* only records the
// target; pass_end encodes one copy pass (vertex upload) followed by one
// render pass replaying the recorded draws — copy passes can't nest inside
// render passes, and this keeps mid-pass texture_create legal.
package gfx

import "base:runtime"
import "core:math"
import sdl "vendor:sdl3"

Render_Target :: struct {
	color, depth:  ^sdl.GPUTexture,
	width, height: i32,
}

_Draw :: struct {
	kind:         _Pipeline_Kind,
	is_mesh:      bool,
	texture:      ^Texture, // nil = white
	vp_index:     i32,
	first_vertex: u32, // batch draws
	vertex_count: u32,
	mesh:         Mesh, // mesh draws
	mesh_first:   u32, // index range within the mesh (submeshes)
	mesh_count:   u32,
	model:        matrix[4, 4]f32,
	color:        [4]f32,
	shader:       string, // mesh draws; "" = DEFAULT_SHADER
	material:     []u8,   // fragment UBO slot 1 bytes (shader property block); nil = none
}

// Must match the GLSL UBO (std140: mat4, mat4, vec4). Batch draws push
// model = identity (vertices are pre-transformed to world space).
_Uniform :: struct {
	view_proj: matrix[4, 4]f32,
	model:     matrix[4, 4]f32,
	tint:      [4]f32,
}

// Must match the lit shader's LightUBO (fragment set=3 binding=0).
_Light_Uniform :: struct {
	dir_ambient: [4]f32, // xyz = normalized direction light travels, w = ambient floor
	color:       [4]f32, // rgb premultiplied by intensity
}

// Matches the previously baked-in lit shader constants, so scenes without a
// Light component keep looking the same.
_LIGHT_DEFAULT :: _Light_Uniform{
	dir_ambient = {-0.42107597, -0.84215194, -0.33686078, 0.35}, // normalize({-0.5,-1,-0.4})
	color       = {1, 1, 1, 1},
}

_pass: struct {
	active:       bool,
	target_color: ^sdl.GPUTexture,
	target_depth: ^sdl.GPUTexture, // nil = depth-less pass (imgui-only)
	clear:        Maybe([4]f32),
	light:        Maybe(_Light_Uniform), // nil = _LIGHT_DEFAULT; reset each pass_end
	vps:          [dynamic]matrix[4, 4]f32,
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
	delete(_pass.vps)
	delete(_pass.vtx)
	delete(_pass.draws)
	_pass = {}
}

rt_create :: proc(width, height: i32) -> ^Render_Target {
	rt := new(Render_Target, runtime.default_allocator())
	rt.width = width
	rt.height = height
	rt.color = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _gfx.swapchain_format,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	rt.depth = sdl.CreateGPUTexture(_gfx.device, sdl.GPUTextureCreateInfo{
		type                 = .D2,
		format               = _DEPTH_FORMAT,
		usage                = {.DEPTH_STENCIL_TARGET},
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
	tmp := rt_create(width, height)
	rt.color = tmp.color
	rt.depth = tmp.depth
	rt.width = width
	rt.height = height
	free(tmp, runtime.default_allocator())
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

pass_begin_target :: proc(rt: ^Render_Target, clear: Maybe([4]f32)) {
	assert(!_pass.active, "gfx pass already active")
	_pass.active = true
	_pass.target_color = rt.color
	_pass.target_depth = rt.depth
	_pass.clear = clear
}

// Acquires the swapchain image; false when the window is minimized (skip
// drawing this frame). The window depth buffer is lazily (re)sized.
// depth=false makes a depth-less pass — REQUIRED when only external
// pipelines without a depth attachment draw in it (the editor's imgui pass);
// our own gfx pipelines must NOT draw in such a pass (they declare D32).
pass_begin_swapchain :: proc(clear: Maybe([4]f32), depth := true) -> bool {
	assert(!_pass.active, "gfx pass already active")
	swap_tex: ^sdl.GPUTexture
	w, h: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(_gfx.cmd, _platform.window, &swap_tex, &w, &h) {
		return false
	}
	if swap_tex == nil do return false

	if !depth {
		_pass.active = true
		_pass.target_color = swap_tex
		_pass.target_depth = nil
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
	_pass.clear = clear
	return true
}

// Directional light for the CURRENT pass's lit-shader draws (one light —
// per-draw light lists are a later problem). direction is the way the light
// travels (sun → scene); zero-length falls back to straight down. Not calling
// this keeps the default (white, baked direction, 0.35 ambient).
set_light :: proc(direction: [3]f32, color: [3]f32, intensity: f32, ambient: f32) {
	d := direction
	len_sq := d.x * d.x + d.y * d.y + d.z * d.z
	if len_sq < 1e-12 {
		d = {0, -1, 0}
	} else {
		d /= math.sqrt(len_sq)
	}
	_pass.light = _Light_Uniform{
		dir_ambient = {d.x, d.y, d.z, clamp(ambient, 0, 1)},
		color       = {color.r * intensity, color.g * intensity, color.b * intensity, 1},
	}
}

// May change mid-pass (multi-camera stacking, screen-space overlays).
set_view_proj :: proc(vp: matrix[4, 4]f32) {
	if len(_pass.vps) > 0 && _pass.vps[len(_pass.vps)-1] == vp do return
	append(&_pass.vps, vp)
}

_MAT4_IDENTITY :: matrix[4, 4]f32{
	1, 0, 0, 0,
	0, 1, 0, 0,
	0, 0, 1, 0,
	0, 0, 0, 1,
}

_current_vp :: proc() -> i32 {
	if len(_pass.vps) == 0 {
		append(&_pass.vps, _MAT4_IDENTITY)
	}
	return i32(len(_pass.vps) - 1)
}

// corners in draw order: bottom-left, bottom-right, top-right, top-left
// (two CCW triangles). tex=nil draws untextured white.
draw_quad :: proc(corners: [4][3]f32, uvs: [4][2]f32, color: [4]f32, tex: ^Texture) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	append(&_pass.vtx,
		Vertex{corners[0], n, uvs[0], c},
		Vertex{corners[1], n, uvs[1], c},
		Vertex{corners[2], n, uvs[2], c},
		Vertex{corners[0], n, uvs[0], c},
		Vertex{corners[2], n, uvs[2], c},
		Vertex{corners[3], n, uvs[3], c},
	)
	_batch_append(.Tris, tex, first, 6)
}

// Untextured filled triangle (white 1x1 texture bound at draw). Winding is
// irrelevant — the pipelines don't cull.
draw_triangle :: proc(a, b, c: [3]f32, color: [4]f32, depth_test := true) {
	col := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	append(&_pass.vtx, Vertex{a, n, {}, col}, Vertex{b, n, {}, col}, Vertex{c, n, {}, col})
	_batch_append(depth_test ? .Tris : .Tris_Overlay, nil, first, 3)
}

// depth_write=true makes the line participate in occlusion both ways (editor
// grid): later depth-tested draws can't paint over closer line pixels.
draw_line :: proc(a, b: [3]f32, color: [4]f32, depth_test := true, depth_write := false) {
	c := _color_u8(color)
	first := u32(len(_pass.vtx))
	n := [3]f32{0, 0, 1}
	kind: _Pipeline_Kind = depth_test ? (depth_write ? .Lines_Depth : .Lines) : .Lines_Overlay
	append(&_pass.vtx, Vertex{a, n, {}, c}, Vertex{b, n, {}, c})
	_batch_append(kind, nil, first, 2)
}

// shader picks a registered shader set (shader_register); ""/unknown names
// fall back to DEFAULT_SHADER. The caller keeps `shader` alive through
// pass_end (material cache / string literals — never temp per-frame builds);
// `material` (property-block UBO bytes for fragment slot 1) may be
// temp-allocated — it's read at pass_end within the same frame.
// index_count=0 draws the whole mesh; a submesh passes its index range.
draw_mesh :: proc(mesh: Mesh, tex: ^Texture, model: matrix[4, 4]f32, color: [4]f32, shader := "", first_index: u32 = 0, index_count: u32 = 0, material: []u8 = nil) {
	if mesh.index_count == 0 do return
	count := index_count == 0 ? mesh.index_count : index_count
	if first_index >= mesh.index_count do return
	count = min(count, mesh.index_count - first_index)
	append(&_pass.draws, _Draw{
		kind       = .Tris_Depth,
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

// Extends the previous draw when pipeline/texture/view match — the common
// case for sprite runs and grid lines.
_batch_append :: proc(kind: _Pipeline_Kind, tex: ^Texture, first: u32, count: u32) {
	vp := _current_vp()
	if len(_pass.draws) > 0 {
		last := &_pass.draws[len(_pass.draws)-1]
		if !last.is_mesh && last.kind == kind && last.texture == tex && last.vp_index == vp &&
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
	})
}

// Encodes the pass: batch upload (copy pass), then the render pass replaying
// draws. before_end runs inside the render pass (the editor renders imgui
// draw data there).
pass_end :: proc(before_end: proc(cmd: ^sdl.GPUCommandBuffer, rp: ^sdl.GPURenderPass) = nil) {
	assert(_pass.active, "gfx pass not active")
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
			load_op          = .CLEAR, // depth is always per-pass scratch
			store_op         = .DONT_CARE,
			stencil_load_op  = .DONT_CARE,
			stencil_store_op = .DONT_CARE,
		}
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, &depth_info)
	} else {
		assert(len(_pass.draws) == 0, "gfx draws recorded in a depth-less pass")
		rp = sdl.BeginGPURenderPass(_gfx.cmd, &color_info, 1, nil)
	}

	// Light uniforms persist on the command buffer for every draw this pass;
	// only pipelines that declare the fragment UBO (lit) consume them.
	light := _pass.light.? or_else _LIGHT_DEFAULT
	sdl.PushGPUFragmentUniformData(_gfx.cmd, 0, &light, size_of(_Light_Uniform))

	bound: ^sdl.GPUGraphicsPipeline
	batch_bound := false
	pushed_vp := i32(-1)
	pushed_mesh := false
	for &d in _pass.draws {
		pipeline := _gfx.pipelines[d.kind]
		if d.shader != "" {
			if set, ok := _gfx.shader_sets[d.shader]; ok do pipeline = set[d.kind]
		}
		if pipeline != bound {
			sdl.BindGPUGraphicsPipeline(rp, pipeline)
			bound = pipeline
			batch_bound = false // vertex buffer binding survives, but re-bind cheaply per pipeline switch
		}
		tex := d.texture != nil ? d.texture : _gfx.white_tex
		binding := sdl.GPUTextureSamplerBinding{texture = tex.gpu, sampler = _gfx.sampler_linear}
		sdl.BindGPUFragmentSamplers(rp, 0, &binding, 1)

		if d.is_mesh {
			u := _Uniform{view_proj = _pass.vps[d.vp_index], model = d.model, tint = d.color}
			sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
			if len(d.material) > 0 {
				// Shader property block (custom shaders' MaterialUBO, slot 1).
				sdl.PushGPUFragmentUniformData(_gfx.cmd, 1, raw_data(d.material), u32(len(d.material)))
			}
			pushed_vp = -1
			pushed_mesh = true

			vb := sdl.GPUBufferBinding{buffer = d.mesh.vbuf}
			sdl.BindGPUVertexBuffers(rp, 0, &vb, 1)
			sdl.BindGPUIndexBuffer(rp, {buffer = d.mesh.ibuf}, ._32BIT)
			sdl.DrawGPUIndexedPrimitives(rp, d.mesh_count, 1, d.mesh_first, 0, 0)
			batch_bound = false
		} else {
			if pushed_vp != d.vp_index || pushed_mesh {
				u := _Uniform{view_proj = _pass.vps[d.vp_index], model = _MAT4_IDENTITY, tint = {1, 1, 1, 1}}
				sdl.PushGPUVertexUniformData(_gfx.cmd, 0, &u, size_of(_Uniform))
				pushed_vp = d.vp_index
				pushed_mesh = false
			}
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
