package mhgui

import "moonhug:engine"

// Marks a node as drawing. What it draws comes from the node's graphic
// (Image); a CanvasRenderer without one draws nothing. Disabling it hides the
// node's graphic without touching the graphic's settings.
@(component={menu="UI/Canvas Renderer"})
@(typ_guid={guid = "56334c3e-5a5d-4a74-981f-3682e7c9dc9a"})
CanvasRenderer :: struct {
	using base: engine.CompData `inspect:"-"`,
}

reset_CanvasRenderer :: proc(cr: ^CanvasRenderer) {
}
