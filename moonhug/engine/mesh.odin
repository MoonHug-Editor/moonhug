package engine

// GUID-keyed mesh cache, mirroring texture2d.odin. Unlike textures, the raw
// glTF is never loaded at runtime — the imported artifact IS the runtime
// format (see asset_importer_mesh.odin); a missing artifact triggers an
// import-then-retry.

import gfx "gfx"
import "core:encoding/uuid"
import "core:os"

Mesh :: struct {
    guid:     Asset_GUID,
    aabb_min: [3]f32, // local-space bounds, for picking and selection outline
    aabb_max: [3]f32,
    gpu:      gfx.Mesh,
}

mesh_cache: map[Asset_GUID]Mesh

mesh_cache_init :: proc() {
    mesh_cache = make(map[Asset_GUID]Mesh)
}

mesh_cache_shutdown :: proc() {
    for _, &mesh in mesh_cache {
        gfx.mesh_destroy(&mesh.gpu)
    }
    delete(mesh_cache)
}

mesh_load :: proc(guid: Asset_GUID) -> (^Mesh, bool) {
    if mesh, ok := &mesh_cache[guid]; ok {
        return mesh, true
    }
    // Headless contexts (tests, scene tooling) have no GPU device.
    if gfx.device() == nil do return nil, false

    artifact := _artifact_path(uuid.Identifier(guid))
    defer delete(artifact)

    blob, read_err := os.read_entire_file(artifact, context.temp_allocator)
    if read_err != nil {
        // Artifact missing (fresh clone, cleaned library/): import from source.
        source_path, path_ok := asset_db_get_path(uuid.Identifier(guid))
        if !path_ok do return nil, false
        if !asset_pipeline_reimport(source_path) do return nil, false
        blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
        if read_err != nil do return nil, false
    }

    header, vertices, indices, parse_ok := _mesh_artifact_parse(blob)
    if !parse_ok do return nil, false

    gpu := gfx.mesh_create(vertices, indices)
    if gpu.index_count == 0 do return nil, false

    mesh_cache[guid] = Mesh{
        guid     = guid,
        aabb_min = header.aabb_min,
        aabb_max = header.aabb_max,
        gpu      = gpu,
    }
    return &mesh_cache[guid], true
}

mesh_unload :: proc(guid: Asset_GUID) {
    if mesh, ok := &mesh_cache[guid]; ok {
        gfx.mesh_destroy(&mesh.gpu)
        delete_key(&mesh_cache, guid)
    }
}
