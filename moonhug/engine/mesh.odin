package engine

// Mesh cache keyed by (guid, part), mirroring texture2d.odin. Unlike
// textures, the raw glTF is never loaded at runtime — the imported artifact
// IS the runtime format (see asset_importer_mesh.odin); a missing OR stale
// artifact (format bump, corruption) triggers an import-then-retry.
// part == 0 is the whole baked model; part == i+1 is glTF mesh i in
// node-local space (MeshFilter.part).

import gfx "gfx"
import "log"
import "base:runtime"
import "core:encoding/uuid"
import "core:os"
import "core:strings"

Mesh :: struct {
    guid:      Asset_GUID,
    aabb_min:  [3]f32, // local-space bounds, for picking and selection outline
    aabb_max:  [3]f32,
    submeshes: []Mesh_Submesh, // per-material index ranges (owned, ≥1)
    gpu:       gfx.Mesh,

    // Skin, empty when the mesh is not skinned. All owned by the cache entry.
    //
    // `bind_vertices` is the artifact's vertex data kept on the CPU: a skinned
    // draw rebuilds vertices from it every frame, so it cannot be dropped after
    // upload the way a static mesh's can.
    skin:          []Mesh_Skin_Vertex,       // parallel to bind_vertices
    bind_vertices: []gfx.Vertex,             // bind-pose positions and normals
    bind_indices:  []u32,                    // the skinned buffer draws these
    inverse_binds: []matrix[4, 4]f32,        // one per joint
    joint_names:   []string,                 // one per joint, for binding
}

mesh_is_skinned :: proc(m: ^Mesh) -> bool {
    return m != nil && len(m.joint_names) > 0
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
    _mesh_parts = make(map[Asset_GUID][]Mesh_Part)
    _mesh_clips = make(map[Asset_GUID][]Mesh_Clip)
}

mesh_cache_shutdown :: proc() {
    for _, &mesh in mesh_cache {
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
        delete(mesh.skin)
        delete(mesh.bind_vertices)
        delete(mesh.bind_indices)
        delete(mesh.inverse_binds)
        for n in mesh.joint_names do delete(n)
        delete(mesh.joint_names)
    }
    delete(mesh_cache)
    delete(_mesh_failed)
    _mesh_failed = nil
    for guid in _mesh_parts do _mesh_parts_free(guid)
    delete(_mesh_parts)
    _mesh_parts = nil
    for guid in _mesh_clips do _mesh_clips_free(guid)
    delete(_mesh_clips)
    _mesh_clips = nil
}

// Part id table per model, from the import settings (sprites' Texture2D
// pattern: cache-owned clones on the process heap, evicted on reimport).
@(private = "file") _mesh_parts: map[Asset_GUID][]Mesh_Part

@(private = "file")
_mesh_parts_free :: proc(guid: Asset_GUID) {
    alloc := runtime.default_allocator()
    if parts, ok := _mesh_parts[guid]; ok {
        for p in parts do delete(p.name, alloc)
        delete(parts, alloc)
    }
}

// The model's part id table, cached from its import settings.
mesh_parts :: proc(guid: Asset_GUID) -> []Mesh_Part {
    if _mesh_parts != nil {
        if parts, ok := _mesh_parts[guid]; ok do return parts
    }

    // Headless contexts (tests, scene tooling) run without the cache — read
    // per call onto the temp allocator instead of caching.
    cached := _mesh_parts != nil
    alloc := cached ? runtime.default_allocator() : context.temp_allocator

    out: []Mesh_Part
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.parts) > 0 {
                out = make([]Mesh_Part, len(ms.parts), alloc)
                for p, i in ms.parts {
                    out[i] = Mesh_Part{id = p.id, name = strings.clone(p.name, alloc)}
                }
            }
        }
    }
    if cached do _mesh_parts[guid] = out // empty result caches too — no re-read per frame
    return out
}

// Resolves a part id to its FILE-ORDER index (the _m<i>.bin artifact).
mesh_part_index :: proc(guid: Asset_GUID, id: Local_ID) -> (i32, bool) {
    for p, i in mesh_parts(guid) {
        if p.id == id do return i32(i), true
    }
    return 0, false
}

// The model's clips, from its settings, cached the same way as parts.
@(private = "file") _mesh_clips: map[Asset_GUID][]Mesh_Clip

@(private = "file")
_mesh_clips_free :: proc(guid: Asset_GUID) {
    alloc := runtime.default_allocator()
    if clips, ok := _mesh_clips[guid]; ok {
        for c in clips do delete(c.name, alloc)
        delete(clips, alloc)
    }
}

mesh_clips :: proc(guid: Asset_GUID) -> []Mesh_Clip {
    if _mesh_clips != nil {
        if clips, ok := _mesh_clips[guid]; ok do return clips
    }
    cached := _mesh_clips != nil
    alloc := cached ? runtime.default_allocator() : context.temp_allocator

    out: []Mesh_Clip
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.clips) > 0 {
                out = make([]Mesh_Clip, len(ms.clips), alloc)
                for c, i in ms.clips {
                    out[i] = Mesh_Clip{id = c.id, name = strings.clone(c.name, alloc), guid = c.guid}
                }
            }
        }
    }
    if cached do _mesh_clips[guid] = out
    return out
}

// Resolves a clip id to its FILE-ORDER index (the _a<i>.bin artifact).
mesh_clip_index :: proc(guid: Asset_GUID, id: Local_ID) -> (i32, bool) {
    for c, i in mesh_clips(guid) {
        if c.id == id do return i32(i), true
    }
    return 0, false
}

// A MeshFilter's PPtr resolved for mesh_load: local_id 0 = the whole model
// (part 0), otherwise the id's part. ok=false when the id no longer exists
// in the model's table — the filter draws nothing, like a missing mesh.
mesh_filter_part :: proc(mf: ^MeshFilter) -> (part: i32, ok: bool) {
    if mf.mesh.local_id == 0 do return 0, true
    idx, found := mesh_part_index(mf.mesh.guid, mf.mesh.local_id)
    if !found do return 0, false
    return idx + 1, true
}

// Loads what a MeshFilter references — the whole model or its part.
mesh_load_filter :: proc(mf: ^MeshFilter) -> (^Mesh, bool) {
    part, ok := mesh_filter_part(mf)
    if !ok do return nil, false
    return mesh_load(mf.mesh.guid, part)
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
    m := Mesh{
        guid      = guid,
        aabb_min  = header.aabb_min,
        aabb_max  = header.aabb_max,
        submeshes = owned_submeshes,
        gpu       = gpu,
    }
    // A skinned mesh keeps its bind pose on the CPU: every frame rebuilds
    // vertices from it, so unlike a static mesh the data outlives the upload.
    if skin, inv, names, sok := _mesh_artifact_parse_skin(blob, header); sok {
        m.skin = make([]Mesh_Skin_Vertex, len(skin))
        copy(m.skin, skin)
        m.bind_vertices = make([]gfx.Vertex, len(vertices))
        copy(m.bind_vertices, vertices)
        m.bind_indices = make([]u32, len(indices))
        copy(m.bind_indices, indices)
        m.inverse_binds = make([]matrix[4, 4]f32, len(inv))
        copy(m.inverse_binds, inv)
        split := mesh_joint_names(names, len(inv), context.temp_allocator)
        m.joint_names = make([]string, len(split))
        for n, i in split do m.joint_names[i] = strings.clone(n)
    }
    mesh_cache[key] = m
    return &mesh_cache[key], true
}

// Drops every cached part of the asset, and lets failed parts try again — this
// is the call a re-import makes, and the new artifact deserves a fresh attempt.
mesh_unload :: proc(guid: Asset_GUID) {
    _mesh_parts_free(guid)
    delete_key(&_mesh_parts, guid)
    _mesh_clips_free(guid)
    delete_key(&_mesh_clips, guid)
    keys := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in mesh_cache {
        if key.guid == guid do append(&keys, key)
    }
    for key in keys {
        mesh := &mesh_cache[key]
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
        delete(mesh.skin)
        delete(mesh.bind_vertices)
        delete(mesh.bind_indices)
        delete(mesh.inverse_binds)
        for n in mesh.joint_names do delete(n)
        delete(mesh.joint_names)
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

// The indices a skinned draw builds its own buffer against — the asset's own,
// kept on the CPU alongside the bind pose.
_mesh_indices_of :: proc(m: ^Mesh) -> []u32 {
    return m != nil ? m.bind_indices : nil
}
