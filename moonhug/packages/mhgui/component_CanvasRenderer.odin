package mhgui

import "moonhug:engine"

// Draws the node's resolved rect as one textured, tinted quad. Graphics
// (Image, Text) will feed it geometry later; until they exist the texture
// and color live here. An empty texture draws the package's white texture,
// so the quad is a solid `color`.
@(component={menu="UI/Canvas Renderer"})
@(typ_guid={guid = "56334c3e-5a5d-4a74-981f-3682e7c9dc9a"})
CanvasRenderer :: struct {
	using base: engine.CompData `inspect:"-"`,
	texture:    engine.Asset_GUID `ext:"png,jpg,jpeg,bmp"`,
	color:      [4]f32 `decor:color()`,
}

reset_CanvasRenderer :: proc(cr: ^CanvasRenderer) {
	cr.color = {1, 1, 1, 1}
}
