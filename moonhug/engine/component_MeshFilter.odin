package engine

// Unity parity: MeshFilter references the mesh DATA; how it draws lives on
// the sibling MeshRenderer. The split lets a future SkinnedMeshRenderer reuse
// the filter. `ext:` limits the Object Picker to mesh assets.

@(component)
@(typ_guid={guid = "32f52908-51a9-4f3b-819b-fc9d8cbc5972"})
MeshFilter :: struct {
    using base: CompData `inspect:"-"`,
    mesh: Asset_GUID `ext:"glb,gltf"`,
}

reset_MeshFilter :: proc(mf: ^MeshFilter) {
}
