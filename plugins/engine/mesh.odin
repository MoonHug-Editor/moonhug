package engine

// Mesh cache keyed by (guid, part), mirroring texture2d.odin. Unlike
// textures, the raw glTF is never loaded at runtime — the imported artifact
// IS the runtime format (see asset_importer_mesh.odin); a missing OR stale
// artifact (format bump, corruption) triggers an import-then-retry.
// part == 0 is the whole baked model; part == i+1 is glTF mesh i in
// node-local space (MeshFilter.part).

import gfx "moonhug:libs/gfx"
import "moonhug:libs/log"
import "base:runtime"
import "core:encoding/uuid"
import "core:os"
import "core:math/rand"
import "core:strings"

Mesh :: struct {
    guid:      Asset_GUID,
    aabb_min:  [3]f32, // local-space bounds, for picking and selection outline
    aabb_max:  [3]f32,
    submeshes: []Mesh_Submesh, // per-material index ranges (owned, ≥1)
    gpu:       gfx.Mesh,

    // Skin, empty when the mesh is not skinned. All owned by the cache entry.
    //
    // `skin_gpu` is the bind pose and the per-vertex joints and weights on the
    // GPU, read by the skinning compute pass of every renderer of this mesh.
    // The posed vertices are per renderer (SkinnedMeshRenderer), the indices
    // are `gpu.ibuf`, shared.
    skin_gpu:      gfx.Skin_Source,
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

// Whether the parts and clips caches are live. A flag, not a nil check on the
// maps: an empty `make(map)` allocates nothing and compares equal to nil until
// its first insert, so a nil check reads "not initialised" forever and nothing
// is ever cached. Mirrors _animation_clip_cache_ready.
@(private = "file") _mesh_cache_ready: bool

// A mesh's positions and triangle indices on the CPU, for a reader that
// needs the shape and not the GPU mesh (a mesh collider). Cached per part
// like mesh_cache and dropped with it by mesh_unload. Loads without a GPU
// device, so it works headless.
Mesh_Geometry :: struct {
    positions: [][3]f32,
    indices:   []u32,
}

@(private = "file") _mesh_geometry: map[Mesh_Key]Mesh_Geometry

mesh_cache_init :: proc() {
    // Cross-frame caches: never the caller's allocator. A test's tracking
    // allocator frees what the test leaves when it ends, which left the global
    // map pointing at freed memory for the next test.
    mesh_cache = make(map[Mesh_Key]Mesh, runtime.default_allocator())
    _mesh_failed = make(map[Mesh_Key]bool, runtime.default_allocator())
    _mesh_geometry = make(map[Mesh_Key]Mesh_Geometry, runtime.default_allocator())
    _mesh_parts = make(map[Asset_GUID][]Mesh_Part, runtime.default_allocator())
    _mesh_clips = make(map[Asset_GUID][]Mesh_Clip, runtime.default_allocator())
    _mesh_hull_sets = make(map[Asset_GUID][]Mesh_Hull_Set, runtime.default_allocator())
    _mesh_cache_ready = true
    // A reimport rewrites the model's artifact and the parts and clips lists
    // in its meta, so both cached lists and every loaded part go with it.
    @(static) hooked := false
    if !hooked {
        hooked = true
        asset_pipeline_add_reimport_hook(mesh_unload)
    }
}

mesh_cache_shutdown :: proc() {
    for _, &mesh in mesh_cache {
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
        gfx.skin_source_destroy(&mesh.skin_gpu)
        delete(mesh.inverse_binds)
        for n in mesh.joint_names do delete(n)
        delete(mesh.joint_names)
    }
    delete(mesh_cache)
    mesh_cache = nil
    delete(_mesh_failed)
    _mesh_failed = nil
    for _, &g in _mesh_geometry do _mesh_geometry_free(&g)
    delete(_mesh_geometry)
    _mesh_geometry = nil
    for guid in _mesh_parts do _mesh_parts_free(guid)
    delete(_mesh_parts)
    _mesh_parts = nil
    for guid in _mesh_clips do _mesh_clips_free(guid)
    delete(_mesh_clips)
    _mesh_clips = nil
    for _, sets in _mesh_hull_sets do delete(sets, runtime.default_allocator())
    delete(_mesh_hull_sets)
    _mesh_hull_sets = nil
    _mesh_cache_ready = false
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
    if _mesh_cache_ready {
        if parts, ok := _mesh_parts[guid]; ok do return parts
    }

    // Headless contexts (tests, scene tooling) run without the cache — read
    // per call onto the temp allocator instead of caching.
    cached := _mesh_cache_ready
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

// Resolves a part id to its FILE-ORDER index, the glTF mesh it is (Mesh_Key.part - 1).
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
    if _mesh_cache_ready {
        if clips, ok := _mesh_clips[guid]; ok do return clips
    }
    cached := _mesh_cache_ready
    alloc := cached ? runtime.default_allocator() : context.temp_allocator

    out: []Mesh_Clip
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.clips) > 0 {
                out = make([]Mesh_Clip, len(ms.clips), alloc)
                for c, i in ms.clips {
                    // Settings stay in the meta. The cache carries identity only.
                    out[i] = Mesh_Clip{id = c.id, name = strings.clone(c.name, alloc), orphan = c.orphan}
                }
            }
        }
    }
    if cached do _mesh_clips[guid] = out
    return out
}

// The model's convex decompositions (Mesh_Hull_Set), from its settings,
// cached the same way as parts. A set is a sub-asset of the model like a
// part or a clip: PPtr{model guid, set id} names it, and its id shares the
// model's id space.
@(private = "file") _mesh_hull_sets: map[Asset_GUID][]Mesh_Hull_Set

mesh_hull_sets :: proc(guid: Asset_GUID) -> []Mesh_Hull_Set {
    if _mesh_cache_ready {
        if sets, ok := _mesh_hull_sets[guid]; ok do return sets
    }
    cached := _mesh_cache_ready
    alloc := cached ? runtime.default_allocator() : context.temp_allocator

    out: []Mesh_Hull_Set
    if path, pok := asset_db_get_path(uuid.Identifier(guid)); pok {
        if settings, sok := asset_pipeline_get_settings(path, context.temp_allocator); sok {
            if ms, is_mesh := settings.(MeshSettings); is_mesh && len(ms.hull_sets) > 0 {
                out = make([]Mesh_Hull_Set, len(ms.hull_sets), alloc)
                copy(out, ms.hull_sets[:])
            }
        }
    }
    if cached do _mesh_hull_sets[guid] = out
    return out
}

// The convex decomposition a reference names, when it names one.
mesh_hull_set_of :: proc(ref: PPtr) -> (Mesh_Hull_Set, bool) {
    if ref.local_id == 0 do return {}, false
    for s in mesh_hull_sets(ref.guid) do if s.id == ref.local_id do return s, true
    return {}, false
}

// A new sub-asset id for content the user adds to a model (a convex
// decomposition): random, positive, and unused by the model's parts, clips
// and sets, so ids from two people's edits never meet and no id is reused.
mesh_new_sub_id :: proc(guid: Asset_GUID, taken: []Local_ID = nil) -> Local_ID {
    for {
        id := Local_ID(rand.int63())
        if id == 0 do continue
        used := false
        for p in mesh_parts(guid) do if p.id == id { used = true; break }
        for c in mesh_clips(guid) do if c.id == id { used = true; break }
        for s in mesh_hull_sets(guid) do if s.id == id { used = true; break }
        for t in taken do if t == id { used = true; break }
        if !used do return id
    }
}

// Resolves a clip id to its position in the model's clip list: real clips in
// glTF file order, orphans after. Orphans have no artifact, so they never
// resolve.
mesh_clip_index :: proc(guid: Asset_GUID, id: Local_ID) -> (i32, bool) {
    for c, i in mesh_clips(guid) {
        if c.id == id do return i32(i), !c.orphan
    }
    return 0, false
}

// A MeshFilter's PPtr resolved for mesh_load: local_id 0 = the whole model
// (part 0), otherwise the id's part. ok=false when the id no longer exists
// in the model's table — the filter draws nothing, like a missing mesh.
mesh_filter_part :: proc(mf: ^MeshFilter) -> (part: i32, ok: bool) {
    return mesh_ref_part(mf.mesh)
}

// A mesh reference's part for mesh_load: the same rule as mesh_filter_part.
mesh_ref_part :: proc(ref: PPtr) -> (part: i32, ok: bool) {
    if ref.local_id == 0 do return 0, true
    idx, found := mesh_part_index(ref.guid, ref.local_id)
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

    blob, header, vertices, indices, submeshes, parse_ok := _mesh_artifact_read(key)
    if !parse_ok do return nil, false

    gpu := gfx.mesh_create(vertices, indices)
    if gpu.index_count == 0 {
        log.errorf("[Mesh] GPU upload produced no indices: %v (part %d, %d verts)", guid, part, len(vertices))
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
    // A skinned mesh uploads its bind pose and skin data a second time, as the
    // storage buffers the skinning compute pass reads.
    if skin, inv, names, sok := _mesh_artifact_parse_skin(blob, header); sok {
        m.skin_gpu = gfx.skin_source_create(vertices, skin)
        m.inverse_binds = make([]matrix[4, 4]f32, len(inv))
        copy(m.inverse_binds, inv)
        split := mesh_joint_names(names, len(inv), context.temp_allocator)
        m.joint_names = make([]string, len(split))
        for n, i in split do m.joint_names[i] = strings.clone(n)
    }
    mesh_cache[key] = m
    return &mesh_cache[key], true
}

// The file of a part: the whole model's artifact for part 0, else the part's
// own file, named by its id. ok=false when the model lists no such part.
@(private = "file")
_mesh_part_file :: proc(whole: string, key: Mesh_Key) -> (string, bool) {
    if key.part == 0 do return whole, true
    parts := mesh_parts(key.guid)
    if int(key.part) > len(parts) do return "", false
    return artifact_sub_path(whole, parts[key.part - 1].id, context.temp_allocator), true
}

// The artifact of one part, read and parsed. The slices point into `blob`,
// temp-allocated. A missing or stale artifact (fresh clone, cleaned library,
// format bump) is imported from source and read once more, and every failure
// marks the key failed: the retry is once per session, not once per frame.
@(private = "file")
_mesh_artifact_read :: proc(key: Mesh_Key) -> (blob: []byte, header: Mesh_Artifact_Header, vertices: []gfx.Vertex, indices: []u32, submeshes: []Mesh_Submesh, ok: bool) {
    whole := _artifact_path(uuid.Identifier(key.guid))
    defer delete(whole)
    artifact, part_ok := _mesh_part_file(whole, key)

    read_err: os.Error
    if part_ok {
        blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
        if read_err == nil {
            header, vertices, indices, submeshes, ok = _mesh_artifact_parse(blob)
        }
        if ok do return
    }

    source_path, path_ok := asset_db_get_path(uuid.Identifier(key.guid))
    if !path_ok {
        _mesh_failed[key] = true
        return
    }
    if !asset_pipeline_request_import(source_path, force = true) {
        _mesh_failed[key] = true
        return
    }
    // The import gave the asset its artifact, so its path is known only now.
    delete(whole)
    whole = _artifact_path(uuid.Identifier(key.guid))
    artifact, part_ok = _mesh_part_file(whole, key)
    if !part_ok {
        log.errorf("[Mesh] %v has no part %d after re-import", key.guid, key.part)
        _mesh_failed[key] = true
        return
    }
    blob, read_err = os.read_entire_file(artifact, context.temp_allocator)
    if read_err != nil {
        log.errorf("[Mesh] artifact unreadable after re-import: %s (part %d)", artifact, key.part)
        _mesh_failed[key] = true
        return
    }
    header, vertices, indices, submeshes, ok = _mesh_artifact_parse(blob)
    if !ok {
        log.errorf("[Mesh] artifact unparseable after re-import: %s (part %d)", artifact, key.part)
        _mesh_failed[key] = true
    }
    return
}

// The positions and indices of a model or a part, on the CPU. Owned by the
// cache: the caller reads and does not free.
mesh_geometry :: proc(guid: Asset_GUID, part: i32 = 0) -> (^Mesh_Geometry, bool) {
    key := Mesh_Key{guid, part}
    if g, ok := &_mesh_geometry[key]; ok do return g, true
    if key in _mesh_failed do return nil, false
    _, _, vertices, indices, _, parse_ok := _mesh_artifact_read(key)
    if !parse_ok do return nil, false
    context.allocator = runtime.default_allocator()
    g := Mesh_Geometry{positions = make([][3]f32, len(vertices)), indices = make([]u32, len(indices))}
    for v, i in vertices do g.positions[i] = v.position
    copy(g.indices, indices)
    _mesh_geometry[key] = g
    return &_mesh_geometry[key], true
}

// The geometry a mesh reference names: the whole model (local_id 0) or its
// part. ok=false when the part no longer exists in the model.
mesh_geometry_of :: proc(ref: PPtr) -> (^Mesh_Geometry, bool) {
    part, ok := mesh_ref_part(ref)
    if !ok do return nil, false
    return mesh_geometry(ref.guid, part)
}

@(private = "file")
_mesh_geometry_free :: proc(g: ^Mesh_Geometry) {
    context.allocator = runtime.default_allocator()
    delete(g.positions)
    delete(g.indices)
}

// Drops every cached part of the asset, and lets failed parts try again — this
// is the call a re-import makes, and the new artifact deserves a fresh attempt.
mesh_unload :: proc(guid: Asset_GUID) {
    _mesh_parts_free(guid)
    delete_key(&_mesh_parts, guid)
    _mesh_clips_free(guid)
    delete_key(&_mesh_clips, guid)
    if sets, ok := _mesh_hull_sets[guid]; ok do delete(sets, runtime.default_allocator())
    delete_key(&_mesh_hull_sets, guid)
    geometry_keys := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in _mesh_geometry {
        if key.guid == guid do append(&geometry_keys, key)
    }
    for key in geometry_keys {
        _mesh_geometry_free(&_mesh_geometry[key])
        delete_key(&_mesh_geometry, key)
    }
    keys := make([dynamic]Mesh_Key, context.temp_allocator)
    for key in mesh_cache {
        if key.guid == guid do append(&keys, key)
    }
    for key in keys {
        mesh := &mesh_cache[key]
        gfx.mesh_destroy(&mesh.gpu)
        delete(mesh.submeshes)
        gfx.skin_source_destroy(&mesh.skin_gpu)
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
