package physics2d

// The Physics Material 2D asset (assets/README.md "Physics materials"): how a
// collider's surface slides and bounces. A collider names one in `material`,
// else takes its Rigidbody2D's, else the Physics 2D settings' default
// material, else the defaults of a new asset.
//
// When two colliders touch, each value is combined from the two with a
// combine mode. The two modes can differ: the one that ranks higher wins,
// Maximum above Minimum above Multiply above Mean above Average, which is the
// enum's own order.
//
// box2d keeps one friction coefficient per shape, for sliding and resting
// alike, and the combine modes travel in the shape's user material id to
// the world's friction and restitution callbacks.

import "base:runtime"
import "core:math"
import "core:strings"
import b2 "vendor:box2d"
import "moonhug:packages/engine"

// In rank order: a higher value wins over a lower one.
Material_Combine2D :: enum u8 {
	Average,
	Mean,     // the geometric mean, sqrt(a * b): box2d's own friction mix
	Multiply,
	Minimum,
	Maximum,  // box2d's own restitution mix
}

@(typ_guid={guid = "e493fc86-9dc9-4b0d-9636-db8c304f435a", menu_assets_create = {menu_name = "Physics Material 2D", file_name = "PhysicsMaterial2D.asset", order = -2}})
PhysicsMaterial2D :: struct {
	// How much a contact resists sliding, from 0 (ice) up.
	friction:         f32 `decor:min(0)`,
	// How much of the speed into a contact comes back out, 0 to 1.
	bounciness:       f32 `decor:range(0, 1)`,
	friction_combine: Material_Combine2D,
	bounce_combine:   Material_Combine2D,
}

reset_PhysicsMaterial2D :: proc(m: ^PhysicsMaterial2D) {
	m^ = {friction = 0.4, friction_combine = .Mean, bounce_combine = .Maximum}
}

// The material `guid` names, cached. Unset is the Physics 2D settings'
// default material, and the defaults of a new asset when that is unset or
// unreadable too.
material_of :: proc(guid: engine.Asset_GUID) -> PhysicsMaterial2D {
	if guid == {} {
		_settings_ensure_loaded()
		d := physics2d_settings.default_material
		return material_of(d) if d != {} else _default_material()
	}
	if m, ok := _materials.cache[guid]; ok do return m
	context.allocator = runtime.default_allocator()
	if _materials.cache == nil do _materials.cache = make(map[engine.Asset_GUID]PhysicsMaterial2D)
	m, ok := engine.asset_load_as(guid, PhysicsMaterial2D)
	if !ok do m = _default_material()
	_materials.cache[guid] = m
	return m
}

// Editor hook: an open document's values replace the cached ones, so an edit
// in the inspector reaches the colliders that use it on the next step.
material_preview :: proc(guid: engine.Asset_GUID, m: PhysicsMaterial2D) {
	context.allocator = runtime.default_allocator()
	if _materials.cache == nil do _materials.cache = make(map[engine.Asset_GUID]PhysicsMaterial2D)
	if prev, had := _materials.cache[guid]; had && prev == m do return
	_materials.cache[guid] = m
	_materials.dirty = true
}

@(private = "file")
_default_material :: proc() -> PhysicsMaterial2D {
	m: PhysicsMaterial2D
	reset_PhysicsMaterial2D(&m)
	return m
}

// The cached materials, and whether one changed since the last step pushed
// materials into the live shapes.
_materials: struct {
	cache: map[engine.Asset_GUID]PhysicsMaterial2D,
	dirty: bool,
	// The settings' default material the live shapes were given.
	default_guid: engine.Asset_GUID,
}

@(init)
_materials_register :: proc "contextless" () {
	context = runtime.default_context()
	engine.asset_db_add_evict_hook(proc(path: string) {
		if !strings.has_suffix(path, ".asset") do return
		guid, ok := engine.asset_db_get_guid(path)
		if !ok do return
		if engine.Asset_GUID(guid) in _materials.cache {
			delete_key(&_materials.cache, engine.Asset_GUID(guid))
			_materials.dirty = true
		}
	})
}

// Puts `m` into a shape's material: friction, restitution, and both combine
// modes in the user material id. Id 0 is a shape box2d made itself, read as
// Mean for friction and Maximum for bounce.
material_apply :: proc(s: ^b2.SurfaceMaterial, m: PhysicsMaterial2D) {
	s.friction = m.friction
	s.restitution = m.bounciness
	s.userMaterialId = i32(1 + int(m.friction_combine) + int(m.bounce_combine) * 16)
}

// Combines two values with the higher-ranked of the two modes their shapes'
// user material ids carry, the friction modes or the bounce modes.
material_combine :: proc "contextless" (a: f32, id_a: i32, b: f32, id_b: i32, bounce: bool) -> f32 {
	mode :: proc "contextless" (id: i32, bounce: bool) -> Material_Combine2D {
		// A shape box2d made itself mixes as box2d does.
		if id <= 0 do return .Maximum if bounce else .Mean
		v := int(id) - 1
		return Material_Combine2D((v / 16) & 0xf) if bounce else Material_Combine2D(v & 0xf)
	}
	switch max(mode(id_a, bounce), mode(id_b, bounce)) {
	case .Average:  return (a + b) * 0.5
	case .Mean:     return math.sqrt(a * b)
	case .Minimum:  return min(a, b)
	case .Multiply: return a * b
	case .Maximum:  return max(a, b)
	}
	return (a + b) * 0.5
}

_combine_friction :: proc "c" (a: f32, id_a: i32, b: f32, id_b: i32) -> f32 {
	return material_combine(a, id_a, b, id_b, false)
}

_combine_bounce :: proc "c" (a: f32, id_a: i32, b: f32, id_b: i32) -> f32 {
	return material_combine(a, id_a, b, id_b, true)
}
