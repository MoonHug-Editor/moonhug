package engine

// The recording buffer behind engine/gizmos (docs/Gizmos.md). Gizmo calls
// append world-space lines, triangles and labels here, and a view draws them
// inside its pass. The data lives in the engine and not in the gizmos package
// so the engine can clear it (a fixed tick starting, Stop) without importing
// that package.
//
// One buffer per UserContext, so a preview world's drawing never shows in the
// scene view. Arrays use the default allocator: they outlive the frame.

// A line (p[0], p[1]) or a triangle, in world space. Lines and triangles share
// one list so they draw in the order they were recorded: shapes drawn without
// depth test paint over each other, and a handle mixes both.
Gizmo_Prim_Kind :: enum u8 {
	Line,
	Triangle,
}

Gizmo_Prim :: struct {
	p:     [3][3]f32,
	color: [4]f32,
	kind:  Gizmo_Prim_Kind,
}

// Draws an icon's symbol with engine/gizmos shapes in -1..1 of the icon
// square.
Gizmo_Symbol :: proc()

// What an icon shows: a symbol drawn with shapes, a glyph of the editor's
// icon font (a Material Symbols codepoint), or a texture asset.
Gizmo_Icon_Image :: union {
	Gizmo_Symbol,
	rune,
	Asset_GUID,
}

// A scene icon (gizmos.icon): kept as data, so each view draws it facing its
// own camera at `px` pixels wide. The scene view selects `owner` on a click
// inside it.
Gizmo_Icon :: struct {
	pos:      [3]f32, // world
	px:       f32,    // width in pixels
	owner:    Transform_Handle,
	image:    Gizmo_Icon_Image,
	color:    [4]f32, // tints a symbol or glyph, multiplies a texture
	backdrop: [4]f32, // a disc behind the image, alpha 0 for none
}

Gizmo_Label :: struct {
	pos:       [3]f32,
	text:      string, // owned (default allocator)
	color:     [4]f32,
	align:     [2]f32, // 0,0 = text starts at the point, 0.5,0.5 = centered
	rotated:   bool,   // read bottom-to-top
	offset_px: [2]f32,
}

// Who a shape is for, drawn in this order. The scene view draws all three, the
// game view .Game and, with its Gizmos toggle, .Editor.
Gizmo_Channel :: enum u8 {
	Game,   // gameplay and @(debug_draw) code
	Editor, // @(on_draw_gizmos) hooks
	Tools,  // handles, the transform gizmo, the selection outline: scene view only
}

// How long a shape stays. .Fixed_Tick: recorded during a fixed tick, kept
// until the next tick starts, so it does not flicker on frames that run no tick.
Gizmo_Lifetime :: enum u8 {
	Frame,
	Fixed_Tick,
}

Gizmo_Batch :: struct {
	prims:  [dynamic]Gizmo_Prim,
	labels: [dynamic]Gizmo_Label,
	icons:  [dynamic]Gizmo_Icon,
}

// [lifetime][channel][depth tested: 0 no, 1 yes]
Gizmo_Buffer :: struct {
	batches: [Gizmo_Lifetime][Gizmo_Channel][2]Gizmo_Batch,
	frame:   u64, // the gfx frame whose shapes the .Frame batches hold
}

// A new frame started (gfx.frame_index moved on): the previous frame's shapes
// go. The gizmos package calls this before every record and draw, so no main
// loop has to end the frame for it.
gizmo_buffer_sync_frame :: proc(buf: ^Gizmo_Buffer, frame_index: u64) {
	if buf.frame == frame_index do return
	gizmo_buffer_clear_lifetime(buf, .Frame)
	buf.frame = frame_index
}

gizmo_batch_clear :: proc(b: ^Gizmo_Batch) {
	for l in b.labels do delete(l.text, b.labels.allocator)
	clear(&b.prims)
	clear(&b.labels)
	clear(&b.icons)
}

gizmo_buffer_clear_lifetime :: proc(buf: ^Gizmo_Buffer, lifetime: Gizmo_Lifetime) {
	for &per_channel in buf.batches[lifetime] {
		for &b in per_channel do gizmo_batch_clear(&b)
	}
}

gizmo_buffer_destroy :: proc(buf: ^Gizmo_Buffer) {
	for &per_lifetime in buf.batches {
		for &per_channel in per_lifetime {
			for &b in per_channel {
				gizmo_batch_clear(&b)
				delete(b.prims)
				delete(b.labels)
				delete(b.icons)
			}
		}
	}
	buf^ = {}
}
