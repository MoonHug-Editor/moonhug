package engine

@(component)
@(typ_guid={guid = "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"})
SpriteRenderer :: struct {
    using base: CompData `inspect:"-"`,
    texture: Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
    // Unity model: the material's shader/tint/properties apply, but its
    // texture slot is REPLACED by the sprite's own texture. Empty = unlit
    // (the default sprite material).
    material: Asset_GUID `ext:"mat"`,
    color:   [4]f32 `decor:color()`,
    // Unity-style sort keys (sprite_sort.odin): layer first, then order in
    // layer, then view depth back-to-front, then scene-tree order.
    sorting_layer:  i32,
    order_in_layer: i32,
}

reset_SpriteRenderer :: proc(sr: ^SpriteRenderer) {
    sr.color = {1, 1, 1, 1}
}
