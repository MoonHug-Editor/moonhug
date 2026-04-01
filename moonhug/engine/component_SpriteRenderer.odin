package engine

@(component)
@(typ_guid={guid = "b7e2a1c3-5d4f-4e8a-9f1b-3c6d8e0a2b4f"})
SpriteRenderer :: struct {
    using base: CompData `inspect:"-"`,
    texture: Asset_GUID,
    color:   [4]f32 `decor:color()`,
}

reset_SpriteRenderer :: proc(sr: ^SpriteRenderer) {
    sr.color = {1, 1, 1, 1}
}
