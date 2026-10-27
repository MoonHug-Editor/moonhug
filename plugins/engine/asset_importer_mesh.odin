package engine

// glTF mesh importer (plugins/engine/docs/SDL3Renderer.md #5, plugins/engine/docs/Meshes.md). One import
// writes:
// - the WHOLE-MODEL artifact (<key>.bin): every node's world transform baked
//   into one vertex blob — what a reference with no local id draws;
// - one PART artifact per glTF mesh (<key>_s<part id>.bin, artifact_sub_path):
//   vertices left in node-local space, so a transform hierarchy (extracted
//   scene, animation) positions them at draw time;
// - one CLIP artifact per glTF animation (<key>_s<clip id>.bin), baked by
//   the animation package.
// Indices are grouped BY MATERIAL into submeshes (Unity model: primitives
// sharing a glTF material merge into one submesh, ordered by first
// appearance — across the file for the whole model, within the mesh for a
// part). MeshRenderer.materials assigns one Material asset per submesh.
// Prefer .glb: a .gltf + external .bin pair works, but the .bin gets its own
// (harmless) guid/meta from the AssetDB walk.

import gfx "moonhug:libs/gfx"
import "core:encoding/json"

// One glTF mesh of the model (Unity's Mesh sub-asset). MeshFilter references
// a part as PPtr{model guid, part id} — the id is the persistent identity,
// minted by the importer and preserved by NAME across reimports (the meta's
// part list is Unity's internalIDToNameTable), so reordering meshes in the
// DCC never retargets a MeshFilter. The name is a view detail.
Mesh_Part :: struct {
    id:   Local_ID,
    name: string,
}

// A clip inside a model: one glTF animation, baked to its own artifact
// (artifact_sub_path with the clip's id). A sub-asset of the model: a `clip: PPtr` field
// names it as {model guid, clip id}, the way it names a standalone .anim as
// {its guid, 0}. Ids share the model's sub-asset id space with parts and
// hull sets and, like parts, are matched by name across reimports, so a clip
// added in the DCC tool never renumbers the rest
// (plugins/animation/docs/AnimationComponent.md).
Mesh_Clip :: struct {
    id:   Local_ID,
    name: string,
    // The clip's import settings (the animation package's
    // Animation_Clip_Settings), kept as a JSON value because that type is the
    // package's, not the engine's. The baker reads it zero → JSON →
    // on_validate. Absent or null = defaults.
    settings: json.Value,
    // The model no longer has a clip by this name. The entry stays so the
    // guid keeps resolving and the user can remap it to a renamed clip
    // instead of losing every reference. Nothing is baked for it.
    orphan: bool,
}

// One convex decomposition the model keeps for its colliders: the hulls of
// one mesh of the model (`part` 0 is the whole model, else a part's id), up
// to `max_hulls`, cut where the mesh strays more than `concavity` (a
// fraction of its size) from a hull. A mesh that is not closed (most game
// meshes, split at uv seams) is first rebuilt as a closed surface on a grid
// of `remesh_resolution` cells along its longest side: the finer the grid,
// the more triangles and the longer the decomposition. A sub-asset of the model: a
// MeshCollider names it as PPtr{model guid, id}. The id is random
// (mesh_new_sub_id), since the user adds sets, so editing or removing others
// never repoints a collider. The physics3d package computes the hulls in the
// editor after an import and keeps them beside the model's artifact.
Mesh_Hull_Set :: struct {
    id:        Local_ID,
    part:      Local_ID,
    max_hulls: i32,
    concavity: f32,
    remesh_resolution: i32,
}

// CoACD's default and range for Mesh_Hull_Set.remesh_resolution.
MESH_HULL_REMESH_DEFAULT :: 50
MESH_HULL_REMESH_MIN :: 20
MESH_HULL_REMESH_MAX :: 100

@(typ_guid={guid="fadd5659-ad40-4e00-95c7-908efc8e8631"})
MeshSettings :: struct {
    scale: f32, // uniform import scale
    // Importer-maintained id table, one entry per glTF mesh IN FILE ORDER
    // (entry i is glTF mesh i, its artifact named by the id). First mint is
    // index + 1.
    parts: [dynamic]Mesh_Part,
    // The id the importer gives the next new part or clip. It only grows, so
    // an id a removed part or clip held is never given to another one: a
    // reference to the removed one stays broken instead of naming the
    // newcomer. 0 in a meta written before the field: the importer starts it
    // above every part and clip id the meta lists.
    next_id: Local_ID `inspect:"-"`,
    // Identity table, not a setting: shown and edited through the selected
    // clip's own section (the animation package, editor/model_clips.odin).
    // The reflected drawer must not walk it, since each entry's settings is a
    // raw JSON value.
    clips: [dynamic]Mesh_Clip `inspect:"-"`,
    // Drawn by the physics3d package's section (Convex Decompositions).
    hull_sets: [dynamic]Mesh_Hull_Set `inspect:"-"`,
}

default_mesh_settings :: proc() -> MeshSettings {
    return MeshSettings{scale = 1}
}

// A zero scale or remesh resolution is no value (a meta predating the
// field): the default.
on_validate_MeshSettings :: proc(s: ^MeshSettings) {
    if s.scale == 0 do s.scale = 1
    // A set written before the field: CoACD's default.
    for &h in s.hull_sets do if h.remesh_resolution == 0 do h.remesh_resolution = MESH_HULL_REMESH_DEFAULT
}

cleanup_MeshSettings :: proc(s: ^MeshSettings) {
    for &p in s.parts do delete(p.name)
    delete(s.parts)
    for &c in s.clips {
        delete(c.name)
        if c.settings != nil do json.destroy_value(c.settings)
    }
    delete(s.clips)
    delete(s.hull_sets)
    s^ = {}
}

reset_MeshSettings :: proc(p: ^MeshSettings) {
    cleanup_MeshSettings(p)
    p^ = default_mesh_settings()
}

// Artifact layout (little-endian), see also _mesh_artifact_parse:
// "MHMESH2\0" | vertex_count u32 | index_count u32 | submesh_count u32 |
// aabb_min [3]f32 | aabb_max [3]f32 | vertices [vertex_count]gfx.Vertex |
// indices [index_count]u32 | submeshes [submesh_count]Mesh_Submesh
// (v2 added the submesh table; stale v1 artifacts fail the magic check and
// mesh_load reimports from source.)
MESH_ARTIFACT_MAGIC :: "MHMESH4\x00" // 3: vertices carry tangents, 4: and a second uv set

Mesh_Artifact_Header :: struct #packed {
    magic:         [8]u8,
    vertex_count:  u32,
    index_count:   u32,
    submesh_count: u32,
    aabb_min:      [3]f32,
    aabb_max:      [3]f32,
    // Skin, 0 when the mesh is not skinned. When set there is one
    // Mesh_Skin_Vertex per vertex, then `joint_count` inverse bind matrices,
    // then `joint_name_bytes` of NUL-separated joint names.
    joint_count:      u32,
    joint_name_bytes: u32,
}

// One vertex's skin binding, up to four joints as glTF allows.
//
// `joints` indexes the SKIN's joint list, NOT glTF node indices. Reading them
// as node indices is the classic "my character explodes" bug. Blender writes
// them as UNSIGNED_BYTE, other exporters as UNSIGNED_SHORT, so the importer
// widens both to u16. The layout is gfx's, since the artifact bytes go to the
// GPU as they are.
Mesh_Skin_Vertex :: gfx.Skin_Vertex

// An index range drawn with one material (materials[i] on the renderer).
Mesh_Submesh :: struct #packed {
    first_index: u32,
    index_count: u32,
}

// Every artifact file one model import wrote: the whole model first, then
// its part and clip files. The import driver moves them together when the
// mesh importer refines its settings.
mesh_artifacts :: proc(artifact_path: string, allocator := context.allocator) -> []string {
    return artifact_files(artifact_path, allocator)
}

// Validates an artifact blob and returns views into it (no copies) — shared
// by mesh_load and the import tests. Fails on stale v1 artifacts (magic
// mismatch). mesh_load reimports from source on parse failure. A part with
// no triangles is a valid artifact with no vertices, indices or submeshes:
// it loads and draws nothing.
_mesh_artifact_parse :: proc(blob: []u8) -> (header: Mesh_Artifact_Header, vertices: []gfx.Vertex, indices: []u32, submeshes: []Mesh_Submesh, ok: bool) {
    if len(blob) < size_of(Mesh_Artifact_Header) do return
    header = (^Mesh_Artifact_Header)(raw_data(blob))^
    if string(header.magic[:]) != MESH_ARTIFACT_MAGIC do return
    if header.submesh_count == 0 && (header.vertex_count != 0 || header.index_count != 0) do return

    vert_bytes := int(header.vertex_count) * size_of(gfx.Vertex)
    index_bytes := int(header.index_count) * size_of(u32)
    submesh_bytes := int(header.submesh_count) * size_of(Mesh_Submesh)
    if len(blob) != size_of(Mesh_Artifact_Header) + vert_bytes + index_bytes + submesh_bytes + _mesh_skin_bytes(header) do return

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

// Bytes the skin sections occupy after the submesh table. Zero when the mesh
// carries no skin.
_mesh_skin_bytes :: proc(h: Mesh_Artifact_Header) -> int {
    if h.joint_count == 0 do return 0
    return int(h.vertex_count) * size_of(Mesh_Skin_Vertex) +
           int(h.joint_count) * size_of(matrix[4, 4]f32) +
           int(h.joint_name_bytes)
}

// The skin sections of an artifact: per-vertex bindings, the inverse bind
// matrix per joint, and the joint names as one NUL-separated blob. All three
// point INTO `blob`, so they live as long as it does.
//
// Names are how a joint finds its transform at bind time — the same name-path
// resolution animation channels use — rather than a node index, which would
// only be meaningful inside the file it came from.
_mesh_artifact_parse_skin :: proc(blob: []u8, header: Mesh_Artifact_Header) -> (skin: []Mesh_Skin_Vertex, inverse_binds: []matrix[4, 4]f32, names: []u8, ok: bool) {
    if header.joint_count == 0 do return nil, nil, nil, false
    off := size_of(Mesh_Artifact_Header) +
        int(header.vertex_count) * size_of(gfx.Vertex) +
        int(header.index_count) * size_of(u32) +
        int(header.submesh_count) * size_of(Mesh_Submesh)
    if off + _mesh_skin_bytes(header) > len(blob) do return nil, nil, nil, false

    skin = ([^]Mesh_Skin_Vertex)(raw_data(blob[off:]))[:header.vertex_count]
    off += int(header.vertex_count) * size_of(Mesh_Skin_Vertex)
    inverse_binds = ([^]matrix[4, 4]f32)(raw_data(blob[off:]))[:header.joint_count]
    off += int(header.joint_count) * size_of(matrix[4, 4]f32)
    names = blob[off:off + int(header.joint_name_bytes)]
    return skin, inverse_binds, names, true
}

// Split the NUL-separated joint name blob. Slices point into `names`.
mesh_joint_names :: proc(names: []u8, count: int, alloc := context.allocator) -> []string {
    out := make([]string, count, alloc)
    start, n := 0, 0
    for i in 0 ..< len(names) {
        if names[i] != 0 do continue
        if n < count do out[n] = string(names[start:i])
        n += 1
        start = i + 1
    }
    return out
}
