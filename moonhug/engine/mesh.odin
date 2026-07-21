package engine

// Mesh cache keyed by (guid, part), mirroring texture2d.odin. Unlike
// textures, the raw glTF is never loaded at runtime — the imported artifact
// IS the runtime format (see asset_importer_mesh.odin); a missing OR stale
// artifact (format bump, corruption) triggers an import-then-retry.
// part == 0 is the whole baked model; part == i+1 is glTF mesh i in
// node-local space (MeshFilter.part).

import gfx "gfx"
import "core:encoding/uuid"
import "core:os"

Mesh :: struct {
    guid:      Asset_GUID,
    aabb_min:  [3]f32, // local-space bounds, for picking and selection outline
    aabb_max:  [3]f32,
    submeshes: []Mesh_Submesh, // per-material index ranges (owned, ≥1)
    gpu:       gfx.Mesh,
}

Mesh_Key :: struct {
    guid: Asset_GUID,
    part: i32,
}

mesh_cache: map[Mesh_Key]Mesh

mesh_cache_init :: proc() {
    mesh_cache = make(map[Mesh_Key]Mesh)
}

mesh_cache_shutdown :: proc() {
    for _, &mesh in mesh_cache {
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
    }
    delete(mesh_cache)
}

mesh_load :: proc(guid: Asset_GUID, part: i32 = 0) -> (^Mesh, bool) {
    key := Mesh_Key{guid, part}
    if mesh, ok := &mesh_cache[key]; ok {
        return mesh, true
    }
    // Headless contexts (tests, scene tooling) have no GPU device.
    if gfx.device() == nil do return nil, false

    whole := _artifact_path(uuid.Identifier(guid))
    defer delete(whole)
    artifact := whole
    if part > 0 {
        artifact = mesh_part_artifact_path(whole, int(part - 1), context.temp_allocator)
    }

    header: Mesh_Artifact_Header
    vertices: []gfx.Vertex
    indices: []u32
    submeshes: []Mesh_Submesh
    parse_ok := false
    blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
    if read_err == nil {
        header, vertices, indices, submeshes, parse_ok = _mesh_artifact_parse(blob)
    }
    if !parse_ok {
        // Artifact missing (fresh clone, cleaned library/) or stale (format
        // bump): import from source and retry once.
        source_path, path_ok := asset_db_get_path(uuid.Identifier(guid))
        if !path_ok do return nil, false
        if !asset_pipeline_reimport(source_path) do return nil, false
        blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
        if read_err != nil do return nil, false
        header, vertices, indices, submeshes, parse_ok = _mesh_artifact_parse(blob)
        if !parse_ok do return nil, false
    }

    gpu := gfx.mesh_create(vertices, indices)
    if gpu.index_count == 0 do return nil, false

    owned_submeshes := make([]Mesh_Submesh, len(submeshes))
    copy(owned_submeshes, submeshes)
    mesh_cache[key] = Mesh{
        guid      = guid,
        aabb_min  = header.aabb_min,
        aabb_max  = header.aabb_max,
        submeshes = owned_submeshes,
        gpu       = gpu,
    }
    return &mesh_cache[key], true
}

// Drops every cached part of the asset.
mesh_unload :: proc(guid: Asset_GUID) {
    keys := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in mesh_cache {
        if key.guid == guid do append(&keys, key)
    }
    for key in keys {
        mesh := &mesh_cache[key]
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
        delete_key(&mesh_cache, key)
    }
}
