package engine

// Draws the sibling MeshFilter's mesh. No material system yet — texture +
// tint mirrors SpriteRenderer's shape; a Material asset is the designated
// follow-up (docs/SDL3Renderer.md).

@(component)
@(typ_guid={guid = "73e161a0-c599-4cfb-9826-447e05baa76c"})
MeshRenderer :: struct {
    using base: CompData `inspect:"-"`,
    texture: Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
    color:   [4]f32 `decor:color()`,
}

reset_MeshRenderer :: proc(mr: ^MeshRenderer) {
    mr.color = {1, 1, 1, 1}
}
