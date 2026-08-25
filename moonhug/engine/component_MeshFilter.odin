package engine

// Unity parity: MeshFilter references the mesh DATA; how it draws lives on
// the sibling MeshRenderer. The split lets a future SkinnedMeshRenderer reuse
// the filter.
//
// `mesh` is the guid+fileID sub-asset reference: guid = the model file,
// local_id = a part's persistent id from the model's import settings
// (Mesh_Part, asset_importer_mesh.odin). local_id 0 = the whole model baked
// into one blob (node world transforms applied at import), a part id = that
// glTF mesh in node-local space, positioned by this transform. Extracted
// scenes (scene_from_gltf) use parts so animated node transforms move real
// geometry. Hidden from the default inspector — the mesh_editor wrapper
// draws the part picker.

@(component)
@(typ_guid={guid = "32f52908-51a9-4f3b-819b-fc9d8cbc5972"})
MeshFilter :: struct {
    using base: CompData `inspect:"-"`,
    mesh: PPtr `inspect:"-"`,
}

reset_MeshFilter :: proc(mf: ^MeshFilter) {
}
