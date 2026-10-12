// GPU skinning. A compute pass reads a mesh's bind-pose vertices and skin data
// through a joint matrix palette and writes posed vertices into an ordinary
// vertex buffer, which the mesh pipeline then draws like any other mesh: no
// vertex format change and no shader variant in the graphics pipelines.
//
// Two objects, split by what is shared:
// - Skin_Source is the bind pose and the per-vertex joints and weights. It is
//   uploaded once per mesh and read by every renderer of that mesh.
// - Skinned_Mesh is one renderer's palette and posed vertex buffer. Its index
//   buffer is BORROWED from the static mesh, since the indices never change.
//
// Both storage buffers are raw words (see shaders/skin.comp.glsl): a vertex is
// 9 words, a skin vertex 6, the palette is a mat4 array.
package gfx

import "base:runtime"
import sdl "vendor:sdl3"

// Per-vertex skin data, parallel to the vertices. u16 joints: Blender writes
// joint indices as UNSIGNED_BYTE and other exporters as UNSIGNED_SHORT, the
// importer widens both. The layout is what the compute shader decodes.
Skin_Vertex :: struct #packed {
	joints:  [4]u16,
	weights: [4]f32,
}

#assert(size_of(Vertex) == 36)
#assert(size_of(Skin_Vertex) == 24)

@(private) _SKIN_COMP_SPV := #load("shaders/compiled/skin.comp.spv")
@(private) _SKIN_COMP_MSL := #load("shaders/compiled/skin.comp.msl")

@(private) _SKIN_THREADS :: 64 // local_size_x in the shader

// The shader's uniform block. 16 bytes so the push is aligned on every backend.
@(private)
_Skin_Params :: struct {
	vertex_count: u32,
	joint_count:  u32,
	_:            [2]u32,
}

// The bind pose on the GPU, shared by every renderer of one mesh.
Skin_Source :: struct {
	bind, skin:   ^sdl.GPUBuffer,
	vertex_count: u32,
}

// One renderer's posed mesh. `mesh.ibuf` is the static mesh's index buffer and
// is not released here.
Skinned_Mesh :: struct {
	using mesh:   Mesh,
	palette:      ^sdl.GPUBuffer,
	transfer:     ^sdl.GPUTransferBuffer, // palette staging, kept across poses
	vertex_count: u32,
	joint_count:  u32,
}

@(private)
_skinning_init :: proc() -> bool {
	formats := sdl.GetGPUShaderFormats(_gfx.device)
	info := sdl.GPUComputePipelineCreateInfo{
		num_readonly_storage_buffers  = 3,
		num_readwrite_storage_buffers = 1,
		num_uniform_buffers           = 1,
		threadcount_x                 = _SKIN_THREADS,
		threadcount_y                 = 1,
		threadcount_z                 = 1,
	}
	if .MSL in formats {
		info.format = {.MSL}
		info.entrypoint = "main0"
		info.code = raw_data(_SKIN_COMP_MSL)
		info.code_size = len(_SKIN_COMP_MSL)
	} else if .SPIRV in formats {
		info.format = {.SPIRV}
		info.entrypoint = "main"
		info.code = raw_data(_SKIN_COMP_SPV)
		info.code_size = len(_SKIN_COMP_SPV)
	} else {
		return false
	}
	_gfx.skin_pipeline = sdl.CreateGPUComputePipeline(_gfx.device, info)
	return _gfx.skin_pipeline != nil
}

@(private)
_skinning_shutdown :: proc() {
	if _gfx.skin_pipeline != nil do sdl.ReleaseGPUComputePipeline(_gfx.device, _gfx.skin_pipeline)
	_gfx.skin_pipeline = nil
}

// Upload the bind pose and skin data. `skin` is parallel to `vertices`.
skin_source_create :: proc(vertices: []Vertex, skin: []Skin_Vertex) -> Skin_Source {
	assert(len(vertices) == len(skin))
	vsize := u32(len(vertices) * size_of(Vertex))
	ssize := u32(len(skin) * size_of(Skin_Vertex))
	if vsize == 0 do return {}

	bind := sdl.CreateGPUBuffer(_gfx.device, {usage = {.COMPUTE_STORAGE_READ}, size = vsize})
	skin_buf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.COMPUTE_STORAGE_READ}, size = ssize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = vsize + ssize})
	if bind == nil || skin_buf == nil || transfer == nil {
		if bind != nil do sdl.ReleaseGPUBuffer(_gfx.device, bind)
		if skin_buf != nil do sdl.ReleaseGPUBuffer(_gfx.device, skin_buf)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}
	defer sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, transfer, false)
	runtime.mem_copy_non_overlapping(mapped, raw_data(vertices), int(vsize))
	runtime.mem_copy_non_overlapping(rawptr(uintptr(mapped) + uintptr(vsize)), raw_data(skin), int(ssize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer}, {buffer = bind, size = vsize}, false)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = transfer, offset = vsize}, {buffer = skin_buf, size = ssize}, false)
	sdl.EndGPUCopyPass(copy_pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)

	return Skin_Source{bind = bind, skin = skin_buf, vertex_count = u32(len(vertices))}
}

skin_source_destroy :: proc(s: ^Skin_Source) {
	if s.bind != nil do sdl.ReleaseGPUBuffer(_gfx.device, s.bind)
	if s.skin != nil do sdl.ReleaseGPUBuffer(_gfx.device, s.skin)
	s^ = {}
}

// A posed vertex buffer for `vertex_count` vertices and a palette of
// `joint_count` matrices, drawn with the static mesh's `ibuf`.
skinned_mesh_create :: proc(vertex_count, joint_count: int, ibuf: ^sdl.GPUBuffer, index_count: u32) -> Skinned_Mesh {
	vsize := u32(vertex_count * size_of(Vertex))
	psize := u32(joint_count * size_of(matrix[4, 4]f32))
	if vsize == 0 || psize == 0 || ibuf == nil do return {}

	vbuf := sdl.CreateGPUBuffer(_gfx.device, {usage = {.VERTEX, .COMPUTE_STORAGE_WRITE}, size = vsize})
	palette := sdl.CreateGPUBuffer(_gfx.device, {usage = {.COMPUTE_STORAGE_READ}, size = psize})
	transfer := sdl.CreateGPUTransferBuffer(_gfx.device, {usage = .UPLOAD, size = psize})
	if vbuf == nil || palette == nil || transfer == nil {
		if vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, vbuf)
		if palette != nil do sdl.ReleaseGPUBuffer(_gfx.device, palette)
		if transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, transfer)
		return {}
	}
	return Skinned_Mesh{
		mesh         = Mesh{vbuf = vbuf, ibuf = ibuf, index_count = index_count},
		palette      = palette,
		transfer     = transfer,
		vertex_count = u32(vertex_count),
		joint_count  = u32(joint_count),
	}
}

// Upload the palette and dispatch the skinning. `palette` is one matrix per
// joint, joint world * inverse bind, so the result is in world space. The
// palette and the posed buffer cycle, so a draw still reading the previous
// pose is never overwritten.
skinned_mesh_pose :: proc(m: ^Skinned_Mesh, src: Skin_Source, palette: []matrix[4, 4]f32) {
	if m.vbuf == nil || src.bind == nil || _gfx.skin_pipeline == nil do return
	n := min(u32(len(palette)), m.joint_count)
	if n == 0 || src.vertex_count != m.vertex_count do return
	psize := n * size_of(matrix[4, 4]f32)

	mapped := sdl.MapGPUTransferBuffer(_gfx.device, m.transfer, true)
	runtime.mem_copy_non_overlapping(mapped, raw_data(palette), int(psize))
	sdl.UnmapGPUTransferBuffer(_gfx.device, m.transfer)

	cmd := sdl.AcquireGPUCommandBuffer(_gfx.device)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(copy_pass, {transfer_buffer = m.transfer}, {buffer = m.palette, size = psize}, true)
	sdl.EndGPUCopyPass(copy_pass)

	out := sdl.GPUStorageBufferReadWriteBinding{buffer = m.vbuf, cycle = true}
	pass := sdl.BeginGPUComputePass(cmd, nil, 0, &out, 1)
	sdl.BindGPUComputePipeline(pass, _gfx.skin_pipeline)
	inputs := [3]^sdl.GPUBuffer{src.bind, src.skin, m.palette}
	sdl.BindGPUComputeStorageBuffers(pass, 0, raw_data(inputs[:]), 3)
	params := _Skin_Params{vertex_count = m.vertex_count, joint_count = n}
	sdl.PushGPUComputeUniformData(cmd, 0, &params, size_of(params))
	sdl.DispatchGPUCompute(pass, (m.vertex_count + _SKIN_THREADS - 1) / _SKIN_THREADS, 1, 1)
	sdl.EndGPUComputePass(pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
}

skinned_mesh_destroy :: proc(m: ^Skinned_Mesh) {
	if m.vbuf != nil do sdl.ReleaseGPUBuffer(_gfx.device, m.vbuf)
	if m.palette != nil do sdl.ReleaseGPUBuffer(_gfx.device, m.palette)
	if m.transfer != nil do sdl.ReleaseGPUTransferBuffer(_gfx.device, m.transfer)
	m^ = {}
}
