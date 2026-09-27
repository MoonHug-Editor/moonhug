package engine

import "base:runtime"
import "core:time"

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

// The clock a timed group expires on (gizmos.with_duration).
Gizmo_Clock :: enum u8 {
	Game, // the simulation: fixed ticks, so it pauses with Pause and restarts on Stop
	Real, // wall time, for editor tools
}

// Shapes that outlive the frame: a timed group (gizmos.with_duration) goes
// when its clock passes `expires`, a keyed group (gizmos.with_key) when its
// key is cleared, or its shapes are replaced when the key records again in a
// later frame.
Gizmo_Group :: struct {
	batches: [Gizmo_Channel][2]Gizmo_Batch,
	key:     u64, // 0: a timed group
	expires: f64,
	clock:   Gizmo_Clock,
	gen:     u64, // keyed: the frame generation it last recorded in
}

// [lifetime][channel][depth tested: 0 no, 1 yes]
Gizmo_Buffer :: struct {
	batches: [Gizmo_Lifetime][Gizmo_Channel][2]Gizmo_Batch,
	groups:  [dynamic]^Gizmo_Group, // default allocator, like the batches
	gen:     u64, // frame boundaries so far (a new gfx frame, gizmos.frame_end)
	frame:   u64, // the gfx frame whose shapes the .Frame batches hold
}

// A new frame started (gfx.frame_index moved on): the previous frame's shapes
// go. The gizmos package calls this before every record and draw, so no main
// loop has to end the frame for it.
gizmo_buffer_sync_frame :: proc(buf: ^Gizmo_Buffer, frame_index: u64) {
	if buf.frame == frame_index do return
	buf.frame = frame_index
	gizmo_buffer_frame_boundary(buf)
}

// A frame ends: its shapes go, and so do timed groups whose clock has passed.
gizmo_buffer_frame_boundary :: proc(buf: ^Gizmo_Buffer) {
	gizmo_buffer_clear_lifetime(buf, .Frame)
	buf.gen += 1
	for i := len(buf.groups) - 1; i >= 0; i -= 1 {
		g := buf.groups[i]
		if g.key == 0 && gizmo_clock_now(g.clock) >= g.expires do _gizmo_group_remove(buf, i)
	}
}

@(private = "file")
_real_start: time.Tick

// Seconds on `clock`.
gizmo_clock_now :: proc(clock: Gizmo_Clock) -> f64 {
	switch clock {
	case .Game:
		return f64(fixed_tick_index()) * f64(fixed_dt())
	case .Real:
		if _real_start == {} do _real_start = time.tick_now()
		return time.duration_seconds(time.tick_since(_real_start))
	}
	return 0
}

// A new timed group, expiring `seconds` from now on `clock`.
gizmo_buffer_timed_group :: proc(buf: ^Gizmo_Buffer, seconds: f32, clock: Gizmo_Clock) -> ^Gizmo_Group {
	g := new(Gizmo_Group, runtime.default_allocator())
	g.expires = gizmo_clock_now(clock) + f64(seconds)
	g.clock = clock
	_gizmo_group_add(buf, g)
	return g
}

// The group for `key`: a new one, or the existing one, cleared first when it
// recorded in an earlier frame (drawing again replaces the shapes).
gizmo_buffer_key_group :: proc(buf: ^Gizmo_Buffer, key: u64) -> ^Gizmo_Group {
	for g in buf.groups {
		if g.key != key do continue
		if g.gen != buf.gen {
			_gizmo_group_clear(g)
			g.gen = buf.gen
		}
		return g
	}
	g := new(Gizmo_Group, runtime.default_allocator())
	g.key = key
	g.gen = buf.gen
	_gizmo_group_add(buf, g)
	return g
}

// Drops `key`'s shapes. false when there are none.
gizmo_buffer_clear_key :: proc(buf: ^Gizmo_Buffer, key: u64) -> bool {
	for g, i in buf.groups {
		if g.key == key {
			_gizmo_group_remove(buf, i)
			return true
		}
	}
	return false
}

// Drops every timed group on `clock` (Stop: the game clock restarts).
gizmo_buffer_clear_clock :: proc(buf: ^Gizmo_Buffer, clock: Gizmo_Clock) {
	for i := len(buf.groups) - 1; i >= 0; i -= 1 {
		g := buf.groups[i]
		if g.key == 0 && g.clock == clock do _gizmo_group_remove(buf, i)
	}
}

@(private = "file")
_gizmo_group_add :: proc(buf: ^Gizmo_Buffer, g: ^Gizmo_Group) {
	if buf.groups == nil do buf.groups = make([dynamic]^Gizmo_Group, 0, 16, runtime.default_allocator())
	append(&buf.groups, g)
}

@(private = "file")
_gizmo_group_clear :: proc(g: ^Gizmo_Group) {
	for &per_channel in g.batches {
		for &b in per_channel do gizmo_batch_clear(&b)
	}
}

@(private = "file")
_gizmo_group_remove :: proc(buf: ^Gizmo_Buffer, i: int) {
	g := buf.groups[i]
	ordered_remove(&buf.groups, i)
	_gizmo_group_destroy(g)
}

@(private = "file")
_gizmo_group_destroy :: proc(g: ^Gizmo_Group) {
	for &per_channel in g.batches {
		for &b in per_channel {
			gizmo_batch_clear(&b)
			delete(b.prims)
			delete(b.labels)
			delete(b.icons)
		}
	}
	free(g, runtime.default_allocator())
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
	for g in buf.groups do _gizmo_group_destroy(g)
	delete(buf.groups)
	buf^ = {}
}
