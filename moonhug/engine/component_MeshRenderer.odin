package engine

// Draws the sibling MeshFilter's mesh with Material assets (material.odin),
// one per submesh (Unity model: submesh i uses materials[i]). Missing or
// empty entries render plain white unlit.

@(component)
@(typ_guid={guid = "73e161a0-c599-4cfb-9826-447e05baa76c"})
MeshRenderer :: struct {
    using base: CompData `inspect:"-"`,
    materials: [dynamic]Asset_GUID `ext:"mat"`,
}

on_destroy_MeshRenderer :: proc(mr: ^MeshRenderer) {
    cleanup_MeshRenderer(mr)
}

cleanup_MeshRenderer :: proc(mr: ^MeshRenderer) {
    if mr.materials != nil do delete(mr.materials)
    comp_zero(mr)
}
