package engine

// Mesh cache keyed by (guid, part), mirroring texture2d.odin. Unlike
// textures, the raw glTF is never loaded at runtime — the imported artifact
// IS the runtime format (see asset_importer_mesh.odin); a missing OR stale
// artifact (format bump, corruption) triggers an import-then-retry.
// part == 0 is the whole baked model; part == i+1 is glTF mesh i in
// node-local space (MeshFilter.part).

import gfx "gfx"
import "log"
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

// Loads that failed, so a broken asset is attempted ONCE rather than on every
// frame that draws it. A failing load re-imports from source, and re-importing
// a glTF several times a second floods the log and stalls the editor — the
// symptom that makes a missing artifact look like a performance bug rather than
// a missing artifact. Mirrors _shader_failed in shader.odin.
//
// Keyed by (guid, part): one unbuildable part must not stop the rest of the
// model loading. Cleared for an asset by mesh_unload, so a re-import or a
// changed file retries.
@(private = "file") _mesh_failed: map[Mesh_Key]bool

mesh_cache_init :: proc() {
    mesh_cache = make(map[Mesh_Key]Mesh)
    _mesh_failed = make(map[Mesh_Key]bool)
}

mesh_cache_shutdown :: proc() {
    for _, &mesh in mesh_cache {
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
    }
    delete(mesh_cache)
    delete(_mesh_failed)
    _mesh_failed = nil
}

mesh_load :: proc(guid: Asset_GUID, part: i32 = 0) -> (^Mesh, bool) {
    key := Mesh_Key{guid, part}
    if mesh, ok := &mesh_cache[key]; ok {
        return mesh, true
    }
    // Known bad: do not re-import it again this session.
    if key in _mesh_failed do return nil, false
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
        // bump): import from source and retry once. Every exit below marks the
        // key failed — the retry is once per session, not once per frame.
        source_path, path_ok := asset_db_get_path(uuid.Identifier(guid))
        if !path_ok {
            _mesh_failed[key] = true
            return nil, false
        }
        if !asset_pipeline_request_import(source_path, force = true) {
            _mesh_failed[key] = true
            return nil, false
        }
        blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
        if read_err != nil {
            log.errorf("[Mesh] artifact unreadable after re-import: %s (part %d)", artifact, part)
            _mesh_failed[key] = true
            return nil, false
        }
        header, vertices, indices, submeshes, parse_ok = _mesh_artifact_parse(blob)
        if !parse_ok {
            log.errorf("[Mesh] artifact unparseable after re-import: %s (part %d)", artifact, part)
            _mesh_failed[key] = true
            return nil, false
        }
    }

    gpu := gfx.mesh_create(vertices, indices)
    if gpu.index_count == 0 {
        log.errorf("[Mesh] GPU upload produced no indices: %s (part %d, %d verts)", artifact, part, len(vertices))
        _mesh_failed[key] = true
        return nil, false
    }

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

// Drops every cached part of the asset, and lets failed parts try again — this
// is the call a re-import makes, and the new artifact deserves a fresh attempt.
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

    failed := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in _mesh_failed {
        if key.guid == guid do append(&failed, key)
    }
    for key in failed {
        delete_key(&_mesh_failed, key)
    }
}
