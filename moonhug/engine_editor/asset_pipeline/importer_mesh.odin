package asset_pipeline

// glTF mesh importer (docs/SDL3Renderer.md #5, docs/Meshes.md). One import
// writes:
// - the WHOLE-MODEL artifact (<guid>.bin): every node's world transform baked
//   into one vertex blob — what MeshFilter.part == 0 draws;
// - one PART artifact per glTF mesh (<guid>_m<i>.bin): vertices left in
//   node-local space, so a transform hierarchy (extracted scene, animation)
//   positions them at draw time — MeshFilter.part == i+1.
// Indices are grouped BY MATERIAL into submeshes (Unity model: primitives
// sharing a glTF material merge into one submesh, ordered by first
// appearance — across the file for the whole model, within the mesh for a
// part). MeshRenderer.materials assigns one Material asset per submesh.
// Prefer .glb: a .gltf + external .bin pair works, but the .bin gets its own
// (harmless) guid/meta from the AssetDB walk.
//
// The artifact FORMAT (header, submesh record, magic, parse) lives in the
// engine (asset_importer_mesh.odin) — runtime mesh loading reads it.

import cgltf "vendor:cgltf"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "moonhug:engine"
import gfx "moonhug:engine/gfx"
import "moonhug:engine/log"

_import_mesh :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
    mesh_settings := settings != nil ? (cast(^engine.MeshSettings)settings)^ : engine.default_mesh_settings()
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
        if load_res == .file_not_found {
            log.errorf("[Pipeline] glTF buffer file missing for %s — a .gltf references an external .bin that must sit next to it (or use .glb)", source_path)
        } else {
            log.errorf("[Pipeline] Failed to load glTF buffers: %s (%v)", source_path, load_res)
        }
        return false
    }

    // Whole model: every mesh node baked through its world transform, buckets
    // ordered by material first-appearance across the file.
    whole := _Mesh_Build{
        vertices = make([dynamic]gfx.Vertex, context.temp_allocator),
        buckets  = make([dynamic]_Submesh_Bucket, context.temp_allocator),
    }
    for &node in data.nodes {
        if node.mesh == nil do continue

        world_flat: [16]f32
        cgltf.node_transform_world(&node, &world_flat[0])
        world := transmute(matrix[4, 4]f32)world_flat // cgltf is column-major, same as Odin

        if !_mesh_append_mesh(&whole, node.mesh, world, scale, source_path) do return false
    }

    total_indices := 0
    for &b in whole.buckets {
        total_indices += len(b.indices)
    }
    if len(whole.vertices) == 0 || total_indices == 0 {
        fmt.printf("[Pipeline] glTF has no triangle geometry: %s\n", source_path)
        return false
    }

    engine._ensure_artifact_dir(artifact_path)
    if !_mesh_write_artifact(artifact_path, &whole) do return false
    fmt.printf("[Pipeline] Imported mesh: %s -> %s (%d verts, %d submeshes)\n",
        source_path, artifact_path, len(whole.vertices), len(whole.buckets))

    // Parts: one artifact per glTF mesh in NODE-LOCAL space (identity
    // transform) — a MeshFilter part reference draws it under its own
    // transform. Meshes several nodes share import once.
    for &mesh, mi in data.meshes {
        part := _Mesh_Build{
            vertices = make([dynamic]gfx.Vertex, context.temp_allocator),
            buckets  = make([dynamic]_Submesh_Bucket, context.temp_allocator),
        }
        if !_mesh_append_mesh(&part, &mesh, linalg.MATRIX4F32_IDENTITY, scale, source_path) do return false
        if len(part.vertices) == 0 do continue
        part_path := engine.mesh_part_artifact_path(artifact_path, mi, context.temp_allocator)
        if !_mesh_write_artifact(part_path, &part) do return false
    }

    // Maintain the part id table in the settings (the driver persists the
    // refinement to the meta): file order, ids preserved by NAME across
    // reimports so DCC reorders never retarget a MeshFilter. First mint is
    // index + 1, new names continue past the highest id. The settings
    // instance lives on the import call's temp allocator
    // (_read_import_meta) — the refined table does too, and the driver
    // marshals it to the meta right after the run.
    if settings != nil {
        ms := cast(^engine.MeshSettings)settings
        old := ms.parts
        ms.parts = make([dynamic]engine.Mesh_Part, context.temp_allocator)
        max_id := engine.Local_ID(0)
        for p in old do max_id = max(max_id, p.id)
        for &mesh, mi in data.meshes {
            name := mesh.name != nil ? string(mesh.name) : fmt.tprintf("mesh_%d", mi)
            id := engine.Local_ID(0)
            for p in old do if p.name == name { id = p.id; break }
            if id == 0 {
                id = len(old) == 0 ? engine.Local_ID(mi + 1) : max_id + 1
                max_id = max(max_id, id)
            }
            append(&ms.parts, engine.Mesh_Part{id = id, name = strings.clone(name, context.temp_allocator)})
        }
    }
    return true
}

// One material-keyed index bucket (nil = "no material") of a build in flight.
_Submesh_Bucket :: struct {
    material: ^cgltf.material,
    indices:  [dynamic]u32,
}

_Mesh_Build :: struct {
    vertices: [dynamic]gfx.Vertex,
    buckets:  [dynamic]_Submesh_Bucket,
}

// Append every triangle primitive of one glTF mesh through `world`, bucketing
// indices by material (first appearance within this build). Returns false
// only on hard import errors (Draco).
_mesh_append_mesh :: proc(build: ^_Mesh_Build, mesh: ^cgltf.mesh, world: matrix[4, 4]f32, scale: f32, source_path: string) -> bool {
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

    for &prim in mesh.primitives {
        if prim.type != .triangles do continue
        if prim.has_draco_mesh_compression {
            log.errorf("[Pipeline] %s uses Draco compression (unsupported) — re-export without compression", source_path)
            return false
        }

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
        for &b in build.buckets {
            if b.material == prim.material {
                bucket = &b
                break
            }
        }
        if bucket == nil {
            append(&build.buckets, _Submesh_Bucket{
                material = prim.material,
                indices  = make([dynamic]u32, context.temp_allocator),
            })
            bucket = &build.buckets[len(build.buckets) - 1]
        }

        base_vertex := u32(len(build.vertices))
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
            append(&build.vertices, v)
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
    return true
}

// Concatenate a build's buckets into the artifact blob and write it.
_mesh_write_artifact :: proc(path: string, build: ^_Mesh_Build) -> bool {
    vertices := &build.vertices
    total_indices := 0
    for &b in build.buckets {
        total_indices += len(b.indices)
    }
    indices := make([dynamic]u32, 0, total_indices, context.temp_allocator)
    submeshes := make([dynamic]engine.Mesh_Submesh, 0, len(build.buckets), context.temp_allocator)
    for &b in build.buckets {
        if len(b.indices) == 0 do continue
        append(&submeshes, engine.Mesh_Submesh{
            first_index = u32(len(indices)),
            index_count = u32(len(b.indices)),
        })
        append(&indices, ..b.indices[:])
    }
    if len(vertices) == 0 || len(indices) == 0 do return false

    header := engine.Mesh_Artifact_Header{
        vertex_count  = u32(len(vertices)),
        index_count   = u32(len(indices)),
        submesh_count = u32(len(submeshes)),
        aabb_min      = vertices[0].position,
        aabb_max      = vertices[0].position,
    }
    copy(header.magic[:], engine.MESH_ARTIFACT_MAGIC)
    for &v in vertices {
        header.aabb_min = linalg.min(header.aabb_min, v.position)
        header.aabb_max = linalg.max(header.aabb_max, v.position)
    }

    blob := make([dynamic]u8, 0, size_of(header) + len(vertices) * size_of(gfx.Vertex) + len(indices) * size_of(u32) + len(submeshes) * size_of(engine.Mesh_Submesh), context.temp_allocator)
    header_bytes := (^[size_of(engine.Mesh_Artifact_Header)]u8)(&header)
    append(&blob, ..header_bytes[:])
    vert_bytes := ([^]u8)(raw_data(vertices^))[:len(vertices) * size_of(gfx.Vertex)]
    append(&blob, ..vert_bytes)
    index_bytes := ([^]u8)(raw_data(indices))[:len(indices) * size_of(u32)]
    append(&blob, ..index_bytes)
    submesh_bytes := ([^]u8)(raw_data(submeshes))[:len(submeshes) * size_of(engine.Mesh_Submesh)]
    append(&blob, ..submesh_bytes)

    if write_err := os.write_entire_file(path, blob[:]); write_err != nil {
        fmt.printf("[Pipeline] Failed to write mesh artifact: %s\n", path)
        return false
    }
    return true
}
