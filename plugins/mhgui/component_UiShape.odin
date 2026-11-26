package mhgui

import "core:encoding/uuid"
import "core:math"
import "core:math/linalg"
import "moonhug:packages/engine"

// The graphic that draws a shape with no sprite: a rectangle with a radius
// per corner, a border, a gradient, a drop shadow and an inner shadow. The
// node also needs a CanvasRenderer, as every graphic does.
//
// The shape is computed per pixel in the shader (assets/shaders/ui_shape.glsl)
// from its size and these fields, so it is one quad at any size, its edge is
// one pixel soft at any canvas scale, and a field can change every frame at
// no cost. The component's color is the fill.
//
// Sizes are in canvas units. A radius is cut to half the shorter side, so a
// large radius on every corner makes a pill or a circle.
@(component={menu="UI/UiShape", icon="SHAPES"})
@(typ_guid={guid = "4405f377-8e06-4b47-804a-f6ed73d030fd"})
UiShape :: struct {
	using base:     engine.CompData `inspect:"-"`,
	// The fields every graphic shares (color, material, raycast target),
	// serialized under "graphic", drawn flat in the inspector. An empty
	// material draws with the package's shape material.
	using graphic:  engine.Graphic `inline:""`,
	kind:           UiShape_Kind,
	// Top left, top right, bottom right, bottom left.
	corner_radius:  [4]f32 `decor:min(0) decor:tooltip(desc="The radius of each corner, in canvas units: top left, top right, bottom right, bottom left. A radius is cut to half the shorter side, so a large one makes a pill or a circle.")`,
	sides:          i32 `decor:range(3, 64) decor:tooltip(desc="Polygon: its sides. Star: its points.")`,
	star_inner:     f32 `decor:range(0.05, 1) decor:tooltip(desc="Star: how far out the notches between its points are, as a share of the points' radius. 0.5 is a classic star.")`,
	point_rounding: f32 `decor:min(0) decor:tooltip(desc="Polygon and Star: how round the points are, in canvas units.")`,
	border_width:   f32 `decor:min(0) decor:tooltip(desc="The border's width from the edge inward, in canvas units. 0 draws none.")`,
	border_color:   [4]f32 `decor:color()`,
	// The fill runs from the color to gradient_color across the shape, along
	// gradient_angle: 0 left to right, 90 bottom to top.
	gradient:       bool `decor:tooltip(desc="The fill runs from the color to the gradient color across the shape.")`,
	gradient_color: [4]f32 `decor:color()`,
	gradient_angle: f32 `decor:tooltip(desc="The gradient's direction in degrees: 0 runs left to right, 90 bottom to top.")`,
	// Behind the shape, may reach outside the rect. It fades with the fill's alpha.
	shadow:         UiShape_Shadow `decor:tooltip(desc="A shadow behind the shape. It draws when its color has alpha.")`,
	// Inside the shape, on the fill.
	inner_shadow:   UiShape_Shadow `decor:tooltip(desc="A shadow inside the shape, on the fill. It draws when its color has alpha.")`,
}

// The outline a UiShape draws.
UiShape_Kind :: enum u8 {
	Rect,    // the node's rect, with a radius per corner
	Ellipse, // the ellipse that fills the rect
	Polygon, // a regular polygon of `sides` sides, a point up, in the largest circle that fits the rect
	Star,    // a star of `sides` points, a point up, in the same circle
}

// A shadow of the shape: the shape moved by `offset`, grown by `spread`,
// its edge faded over `blur`. Alpha 0 in the color draws none.
UiShape_Shadow :: struct {
	color:  [4]f32 `decor:color()`,
	offset: [2]f32,
	blur:   f32 `decor:min(0)`,
	spread: f32,
}

type_reset_UiShape :: proc(s: ^UiShape) {
	s.color = {1, 1, 1, 1}
	s.raycast_target = true
	s.corner_radius = {8, 8, 8, 8}
	s.sides = 5
	s.star_inner = 0.5
	s.border_color = {0, 0, 0, 1}
	s.gradient_color = {1, 1, 1, 1}
	s.shadow = {color = {0, 0, 0, 0}, offset = {0, -4}, blur = 8}
	s.inner_shadow = {color = {0, 0, 0, 0}, offset = {0, -2}, blur = 4}
}

// The material a UiShape draws with when its own is empty
// (assets/materials/UiUiShape.mat, meta committed with it).
UI_SHAPE_MATERIAL_GUID :: "346580f8-0bbf-4885-ae8e-047e54e0d471"

ui_shape_material_guid :: proc() -> engine.Asset_GUID {
	@(static) guid: engine.Asset_GUID
	if engine.asset_guid_is_empty(guid) {
		if g, err := uuid.read(UI_SHAPE_MATERIAL_GUID); err == nil do guid = engine.Asset_GUID(g)
	}
	return guid
}

// How far past the rect the UiShape's quad reaches on every side: the room
// its drop shadow needs, 0 without one.
ui_shape_margin :: proc(s: ^UiShape) -> f32 {
	sh := s.shadow
	if sh.color.a <= 0 do return 0
	return math.ceil(max(abs(sh.offset.x), abs(sh.offset.y)) + max(sh.blur, 0) + max(sh.spread, 0) + 1)
}

// The UiShape's geometry: one quad over the rect, grown by the shadow's
// margin, with the shape's values for the shader.
@(canvas_graphic)
canvas_populate_UiShape :: proc(s: ^UiShape, rect: engine.Rect, out: ^[dynamic]engine.Graphic_Quad) {
	if rect.size.x <= 0 || rect.size.y <= 0 do return
	m := ui_shape_margin(s)
	quad_size := rect.size + 2 * m
	// The CanvasRenderer's tint (a Button's transition) reaches the fill
	// through the quad's color. The shape's other colors take it here.
	tint := [4]f32{1, 1, 1, 1}
	if s.owner != {} {
		if _, cr := engine.transform_get_comp(s.owner, engine.CanvasRenderer); cr != nil && cr.tinted do tint = cr.tint
		// A CanvasGroup fades the whole shape, not its fill alone.
		tint.a *= engine.canvas_group_state(s.owner).alpha
	}
	props := make([]engine.Draw_Property, 10, context.temp_allocator)
	props[0] = {"shape_size", {rect.size.x, rect.size.y, quad_size.x, quad_size.y}}
	props[1] = {"shape_radii", s.corner_radius}
	props[2] = {"shape_params", {max(s.border_width, 0), math.to_radians(s.gradient_angle), 1 if s.gradient else 0, 0}}
	props[3] = {"border_color", s.border_color * tint}
	props[4] = {"gradient_color", s.gradient_color * tint}
	props[5] = {"shadow_color", s.shadow.color * {1, 1, 1, tint.a}}
	props[6] = {"shadow_params", {s.shadow.offset.x, s.shadow.offset.y, max(s.shadow.blur, 0), s.shadow.spread}}
	props[7] = {"inner_shadow_color", s.inner_shadow.color * {1, 1, 1, tint.a}}
	props[8] = {"inner_shadow_params", {s.inner_shadow.offset.x, s.inner_shadow.offset.y, max(s.inner_shadow.blur, 0), s.inner_shadow.spread}}
	// sides 0 is a component saved before the field: a pentagon.
	sides := f32(s.sides) if s.sides >= 3 else 5
	props[9] = {"shape_kind", {f32(s.kind), sides, s.star_inner if s.star_inner > 0 else 0.5, max(s.point_rounding, 0)}}
	append(out, engine.Graphic_Quad{
		pos        = rect.pos - m,
		size       = quad_size,
		uvs        = {{0, 0}, {1, 0}, {1, 1}, {0, 1}},
		texture    = white_texture_guid(),
		material   = ui_shape_material_guid(),
		properties = props,
	})
}

// The signed distance from `p`, counted from the rect's centre with y up, to
// the outline the UiShape draws in a rect of half size `half`: negative
// inside. The same outline as the shader's (assets/shaders/ui_shape.glsl
// shape_sd), without the shadows.
ui_shape_distance :: proc(s: ^UiShape, half: [2]f32, p: [2]f32) -> f32 {
	limit := min(half.x, half.y)
	switch s.kind {
	case .Ellipse:
		k0 := linalg.length(p / half)
		k1 := linalg.length(p / (half * half))
		return k0 * (k0 - 1) / k1 if k1 > 0 else -limit
	case .Polygon, .Star:
		n := f32(s.sides) if s.sides >= 3 else 5
		inner := math.cos(math.PI / n)
		if s.kind == .Star do inner = clamp(s.star_inner if s.star_inner > 0 else 0.5, 0.05, 1)
		round_by := clamp(s.point_rounding, 0, limit * 0.9)
		r := limit - round_by
		an := math.PI / n
		// Folded into half of the sector between two points, a point up.
		angle := math.atan2(p.x, p.y)
		bn := angle - 2 * an * math.floor(angle / (2 * an)) - an
		q := linalg.length(p) * [2]f32{math.cos(bn), abs(math.sin(bn))}
		a := r * [2]f32{math.cos(an), math.sin(an)}
		b := [2]f32{r * inner, 0}
		e := b - a
		w := q - a
		h := clamp(linalg.dot(w, e) / linalg.dot(e, e), 0, 1)
		d := linalg.length(w - e * h)
		return (-d if w.x * e.y - w.y * e.x > 0 else d) - round_by
	case .Rect:
	}
	radii := s.corner_radius
	r := radii.y if p.y > 0 else radii.z
	if p.x <= 0 do r = radii.x if p.y > 0 else radii.w
	r = clamp(r, 0, limit)
	q := [2]f32{abs(p.x) - half.x + r, abs(p.y) - half.y + r}
	return min(max(q.x, q.y), 0) + linalg.length([2]f32{max(q.x, 0), max(q.y, 0)}) - r
}

// The pointer hits a UiShape inside its outline: the cut-away corner of a
// rounded card, and the room between a star's points, take no pointer. The
// shadow is no part of it.
@(canvas_hit)
canvas_hit_UiShape :: proc(s: ^UiShape, rect: engine.Rect, point: [2]f32) -> bool {
	half := rect.size * 0.5
	if half.x <= 0 || half.y <= 0 do return false
	return ui_shape_distance(s, half, point - (rect.pos + half)) <= 0
}
