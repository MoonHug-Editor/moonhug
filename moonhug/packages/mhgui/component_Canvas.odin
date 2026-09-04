package mhgui

import "moonhug:engine"

// The root of a mhgui tree, in screen-space overlay mode: its rect is the
// whole game viewport in pixels, and everything under it draws over the
// scene. Canvases stack by sort_order.
@(component={menu="UI/Canvas"})
@(typ_guid={guid = "ba2db3cd-79be-4d26-9cab-be3fc317d685"})
Canvas :: struct {
	using base: engine.CompData `inspect:"-"`,
	sort_order: i32, // higher draws over lower canvases
}

reset_Canvas :: proc(c: ^Canvas) {
}
