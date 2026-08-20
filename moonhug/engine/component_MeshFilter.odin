package engine

// Unity parity: MeshFilter references the mesh DATA; how it draws lives on
// the sibling MeshRenderer. The split lets a future SkinnedMeshRenderer reuse
// the filter. `ext:` limits the Object Picker to mesh assets.
//
// `part` selects WHICH mesh of the file draws: 0 = the whole model baked into
// one blob (node world transforms applied at import), N = glTF mesh N-1 in
// node-local space, positioned by this transform. Extracted scenes
// (scene_from_gltf) use parts so animated node transforms move real geometry.
// 0 instead of -1 so scenes saved before the field existed keep drawing the
// whole model (absent JSON fields load as zero).

@(component)
@(typ_guid={guid = "32f52908-51a9-4f3b-819b-fc9d8cbc5972"})
MeshFilter :: struct {
    using base: CompData `inspect:"-"`,
    mesh: Asset_GUID `ext:"glb,gltf"`,
    part: i32,
}

reset_MeshFilter :: proc(mf: ^MeshFilter) {
}
