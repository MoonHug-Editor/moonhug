package engine

// glTF mesh importer (docs/SDL3Renderer.md #5). Bakes every node's world
// transform into ONE vertex blob; indices are grouped BY MATERIAL into
// submeshes (Unity model: primitives sharing a glTF material merge into one
// submesh, ordered by first appearance). MeshRenderer.materials assigns one
// Material asset per submesh. Prefer .glb: a .gltf + external .bin pair
// works, but the .bin gets its own (harmless) guid/meta from the AssetDB walk.

import gfx "gfx"
import cgltf "vendor:cgltf"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"

@(typ_guid={guid="fadd5659-ad40-4e00-95c7-908efc8e8631"})
MeshSettings :: struct {
    scale: f32, // uniform import scale
}

default_mesh_settings :: proc() -> MeshSettings {
    return MeshSettings{scale = 1}
}

// Artifact layout (little-endian), see also _mesh_artifact_parse:
// "MHMESH2\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
// aabb_min [3]f32 | aabb_max [3]f32 | vertices [vertex_count]gfx.Vertex |
// indices [index_count]u32 | submeshes [submesh_count]Mesh_Submesh
// (v2 added the submesh table; stale v1 artifacts fail the magic check and
// mesh_load reimports from source.)
MESH_ARTIFACT_MAGIC :: "MHMESH2\x00"

Mesh_Artifact_Header :: struct #packed {
    magic:         [8]u8,
    vertex_count:  u32,
    index_count:   u32,
    submesh_count: u32,
    aabb_min:      [3]f32,
    aabb_max:      [3]f32,
}

// An index range drawn with one material (materials[i] on the renderer).
Mesh_Submesh :: struct #packed {
    first_index: u32,
    index_count: u32,
}

_import_mesh :: proc(source_path: string, artifact_path: string, settings: ImportSettings) -> bool {
    mesh_settings, is_mesh := settings.(MeshSettings)
    if !is_mesh do mesh_settings = default_mesh_settings()
    scale := mesh_settings.scale > 0 ? mesh_settings.scale : 1

    path_c := strings.clone_to_cstring(source_path, context.temp_allocator)
    opts := cgltf.options{}
    data, parse_res := cgltf.parse_file(opts, path_c)
    if parse_res != .success {
        fmt.printf("[Pipeline] Failed to parse glTF: %s (%v)\n", source_path, parse_res)
        return false
    }
    defer cgltf.free(data)

    if load_res := cgltf.load_buffers(opts, data, path_c); load_res != .success {
        fmt.printf("[Pipeline] Failed to load glTF buffers: %s (%v)\n", source_path, load_res)
        return false
    }

    // One shared vertex blob; indices bucketed per glTF material (submesh =
    // bucket, ordered by first appearance across the whole file).
    _Submesh_Bucket :: struct {
        material: ^cgltf.material, // nil = "no material" bucket
        indices:  [dynamic]u32,
    }
    vertices := make([dynamic]gfx.Vertex, context.temp_allocator)
    buckets := make([dynamic]_Submesh_Bucket, context.temp_allocator)

    for &node in data.nodes {
        if node.mesh == nil do continue

        world_flat: [16]f32
        cgltf.node_transform_world(&node, &world_flat[0])
        world := transmute(matrix[4, 4]f32)world_flat // cgltf is column-major, same as Odin

        // Rotation/scale part for normals (unlit shader — plain rotation is
        // fine; inverse-transpose only matters once lighting lands).
        normal_mat := matrix[3, 3]f32{
            world[0, 0], world[0, 1], world[0, 2],
            world[1, 0], world[1, 1], world[1, 2],
            world[2, 0], world[2, 1], world[2, 2],
        }
        // Negative-scale nodes mirror the geometry: flip triangle winding so
        // front faces stay front once backface culling is enabled.
        flip_winding := linalg.determinant(normal_mat) < 0

        for &prim in node.mesh.primitives {
            if prim.type != .triangles do continue

            pos_acc, norm_acc, uv_acc: ^cgltf.accessor
            for &attr in prim.attributes {
                #partial switch attr.type {
                case .position:
                    if pos_acc == nil do pos_acc = attr.data
                case .normal:
                    if norm_acc == nil do norm_acc = attr.data
                case .texcoord:
                    if uv_acc == nil && attr.index == 0 do uv_acc = attr.data
                }
            }
            if pos_acc == nil do continue

            bucket: ^_Submesh_Bucket
            for &b in buckets {
                if b.material == prim.material {
                    bucket = &b
                    break
                }
            }
            if bucket == nil {
                append(&buckets, _Submesh_Bucket{
                    material = prim.material,
                    indices  = make([dynamic]u32, context.temp_allocator),
                })
                bucket = &buckets[len(buckets) - 1]
            }

            base_vertex := u32(len(vertices))
            vcount := uint(pos_acc.count)

            for vi in 0 ..< vcount {
                v: gfx.Vertex
                v.color = {255, 255, 255, 255}

                p: [3]f32
                _ = cgltf.accessor_read_float(pos_acc, vi, &p[0], 3)
                p4 := world * [4]f32{p.x, p.y, p.z, 1}
                v.position = p4.xyz * scale

                if norm_acc != nil && vi < uint(norm_acc.count) {
                    n: [3]f32
                    _ = cgltf.accessor_read_float(norm_acc, vi, &n[0], 3)
                    v.normal = linalg.normalize0(normal_mat * n)
                } else {
                    v.normal = {0, 0, 1} // flat fallback; fine for unlit
                }
                if uv_acc != nil && vi < uint(uv_acc.count) {
                    _ = cgltf.accessor_read_float(uv_acc, vi, &v.uv[0], 2)
                }
                append(&vertices, v)
            }

            first_index := len(bucket.indices)
            if prim.indices != nil {
                icount := uint(prim.indices.count)
                prim_indices := make([]u32, icount, context.temp_allocator)
                _ = cgltf.accessor_unpack_indices(prim.indices, raw_data(prim_indices), size_of(u32), icount)
                for idx in prim_indices {
                    append(&bucket.indices, base_vertex + idx)
                }
            } else {
                for vi in 0 ..< u32(vcount) {
                    append(&bucket.indices, base_vertex + vi)
                }
            }
            if flip_winding {
                for tri := first_index; tri + 2 < len(bucket.indices); tri += 3 {
                    bucket.indices[tri + 1], bucket.indices[tri + 2] = bucket.indices[tri + 2], bucket.indices[tri + 1]
                }
            }
        }
    }

    total_indices := 0
    for &b in buckets {
        total_indices += len(b.indices)
    }
    if len(vertices) == 0 || total_indices == 0 {
        fmt.printf("[Pipeline] glTF has no triangle geometry: %s\n", source_path)
        return false
    }

    // Concatenate buckets into the final index blob + submesh table.
    indices := make([dynamic]u32, 0, total_indices, context.temp_allocator)
    submeshes := make([dynamic]Mesh_Submesh, 0, len(buckets), context.temp_allocator)
    for &b in buckets {
        append(&submeshes, Mesh_Submesh{
            first_index = u32(len(indices)),
            index_count = u32(len(b.indices)),
        })
        append(&indices, ..b.indices[:])
    }

    header := Mesh_Artifact_Header{
        vertex_count  = u32(len(vertices)),
        index_count   = u32(len(indices)),
        submesh_count = u32(len(submeshes)),
        aabb_min      = vertices[0].position,
        aabb_max      = vertices[0].position,
    }
    copy(header.magic[:], MESH_ARTIFACT_MAGIC)
    for &v in vertices {
        header.aabb_min = linalg.min(header.aabb_min, v.position)
        header.aabb_max = linalg.max(header.aabb_max, v.position)
    }

    blob := make([dynamic]u8, 0, size_of(header) + len(vertices) * size_of(gfx.Vertex) + len(indices) * size_of(u32) + len(submeshes) * size_of(Mesh_Submesh), context.temp_allocator)
    header_bytes := (^[size_of(Mesh_Artifact_Header)]u8)(&header)
    append(&blob, ..header_bytes[:])
    vert_bytes := ([^]u8)(raw_data(vertices))[:len(vertices) * size_of(gfx.Vertex)]
    append(&blob, ..vert_bytes)
    index_bytes := ([^]u8)(raw_data(indices))[:len(indices) * size_of(u32)]
    append(&blob, ..index_bytes)
    submesh_bytes := ([^]u8)(raw_data(submeshes))[:len(submeshes) * size_of(Mesh_Submesh)]
    append(&blob, ..submesh_bytes)

    _ensure_artifact_dir(artifact_path)
    if write_err := os.write_entire_file(artifact_path, blob[:]); write_err != nil {
        fmt.printf("[Pipeline] Failed to write mesh artifact: %s\n", artifact_path)
        return false
    }

    fmt.printf("[Pipeline] Imported mesh: %s -> %s (%d verts, %d indices, %d submeshes)\n",
        source_path, artifact_path, header.vertex_count, header.index_count, header.submesh_count)
    return true
}

// Validates an artifact blob and returns views into it (no copies) — shared
// by mesh_load and the import tests. Fails on stale v1 artifacts (magic
// mismatch); mesh_load reimports from source on parse failure.
_mesh_artifact_parse :: proc(blob: []u8) -> (header: Mesh_Artifact_Header, vertices: []gfx.Vertex, indices: []u32, submeshes: []Mesh_Submesh, ok: bool) {
    if len(blob) < size_of(Mesh_Artifact_Header) do return
    header = (^Mesh_Artifact_Header)(raw_data(blob))^
    if string(header.magic[:]) != MESH_ARTIFACT_MAGIC do return
    if header.submesh_count == 0 do return

    vert_bytes := int(header.vertex_count) * size_of(gfx.Vertex)
    index_bytes := int(header.index_count) * size_of(u32)
    submesh_bytes := int(header.submesh_count) * size_of(Mesh_Submesh)
    if len(blob) != size_of(Mesh_Artifact_Header) + vert_bytes + index_bytes + submesh_bytes do return

    verts_ptr := raw_data(blob[size_of(Mesh_Artifact_Header):])
    vertices = ([^]gfx.Vertex)(verts_ptr)[:header.vertex_count]
    idx_ptr := raw_data(blob[size_of(Mesh_Artifact_Header) + vert_bytes:])
    indices = ([^]u32)(idx_ptr)[:header.index_count]
    sub_ptr := raw_data(blob[size_of(Mesh_Artifact_Header) + vert_bytes + index_bytes:])
    submeshes = ([^]Mesh_Submesh)(sub_ptr)[:header.submesh_count]

    // Ranges must stay inside the index blob (defense against corrupt cache).
    for s in submeshes {
        if int(s.first_index) + int(s.index_count) > int(header.index_count) do return {}, nil, nil, nil, false
    }
    return header, vertices, indices, submeshes, true
}
