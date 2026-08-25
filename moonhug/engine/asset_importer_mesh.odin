package engine

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

import gfx "gfx"
import "core:fmt"
import "core:strings"

// One glTF mesh of the model (Unity's Mesh sub-asset). MeshFilter references
// a part as PPtr{model guid, part id} — the id is the persistent identity,
// minted by the importer and preserved by NAME across reimports (the meta's
// part list is Unity's internalIDToNameTable), so reordering meshes in the
// DCC never retargets a MeshFilter. The name is a view detail.
Mesh_Part :: struct {
    id:   Local_ID,
    name: string,
}

@(typ_guid={guid="fadd5659-ad40-4e00-95c7-908efc8e8631", makeProcName=make_pMeshSettings})
MeshSettings :: struct {
    scale: f32, // uniform import scale
    // Importer-maintained id table, one entry per glTF mesh IN FILE ORDER
    // (entry i names part artifact _m<i>.bin). First mint is index + 1.
    parts: [dynamic]Mesh_Part,
}

default_mesh_settings :: proc() -> MeshSettings {
    return MeshSettings{scale = 1}
}

make_pMeshSettings :: proc() -> any {
    p := new(MeshSettings)
    p^ = default_mesh_settings()
    return p^
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

// "<artifact minus .bin>_m<i>.bin" — the per-glTF-mesh part artifact.
mesh_part_artifact_path :: proc(artifact_path: string, mesh_index: int, alloc := context.allocator) -> string {
    base := strings.trim_suffix(artifact_path, ".bin")
    return fmt.aprintf("%s_m%d.bin", base, mesh_index, allocator = alloc)
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
