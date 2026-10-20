package physics3d

// The Physics Material asset (assets/README.md "Physics materials"): how a
// collider's surface slides and bounces. A collider names one in `material`,
// else takes the Physics 3D settings' default material, else the defaults of
// a new asset.
//
// When two colliders touch, each value is combined from the two with a
// combine mode. The two modes can differ: the one that ranks higher wins,
// Maximum above Multiply above Minimum above Average.
//
// box3d keeps one friction coefficient per shape, for sliding and resting
// alike, and the combine modes travel in the shape's user material id to
// the world's friction and restitution callbacks.

import "base:runtime"
import "core:strings"
import b3 "vendor:box3d"
import "moonhug:packages/engine"

Material_Combine :: enum u8 {
	Average,
	Minimum,
	Multiply,
	Maximum,
}

@(typ_guid={guid = "2f42e801-bc46-42c0-ba13-d3d8c3e2a2c6", menu_assets_create = {menu_name = "Physics Material", file_name = "PhysicsMaterial.asset", order = -2}})
PhysicsMaterial :: struct {
	// How much a contact resists sliding, from 0 (ice) up.
	friction:         f32 `decor:min(0)`,
	// How much of the speed into a contact comes back out, 0 to 1.
	bounciness:       f32 `decor:range(0, 1)`,
	friction_combine: Material_Combine,
	bounce_combine:   Material_Combine,
}

reset_PhysicsMaterial :: proc(m: ^PhysicsMaterial) {
	m^ = {friction = 0.6}
}

// The material `guid` names, cached. Unset is the Physics 3D settings'
// default material, and the defaults of a new asset when that is unset or
// unreadable too.
material_of :: proc(guid: engine.Asset_GUID) -> PhysicsMaterial {
	if guid == {} {
		_settings_ensure_loaded()
		d := physics3d_settings.default_material
		return material_of(d) if d != {} else _default_material()
	}
	if m, ok := _materials.cache[guid]; ok do return m
	context.allocator = runtime.default_allocator()
	if _materials.cache == nil do _materials.cache = make(map[engine.Asset_GUID]PhysicsMaterial)
	m, ok := engine.asset_load_as(guid, PhysicsMaterial)
	if !ok do m = _default_material()
	_materials.cache[guid] = m
	return m
}

// Editor hook: an open document's values replace the cached ones, so an edit
// in the inspector reaches the colliders that use it on the next step.
material_preview :: proc(guid: engine.Asset_GUID, m: PhysicsMaterial) {
	context.allocator = runtime.default_allocator()
	if _materials.cache == nil do _materials.cache = make(map[engine.Asset_GUID]PhysicsMaterial)
	if prev, had := _materials.cache[guid]; had && prev == m do return
	_materials.cache[guid] = m
	_materials.dirty = true
}

@(private = "file")
_default_material :: proc() -> PhysicsMaterial {
	m: PhysicsMaterial
	reset_PhysicsMaterial(&m)
	return m
}

// The cached materials, and whether one changed since the last step pushed
// materials into the live shapes.
_materials: struct {
	cache: map[engine.Asset_GUID]PhysicsMaterial,
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
// modes in the user material id. Id 0 is a shape box3d made itself, read as
// Average.
material_apply :: proc(s: ^b3.SurfaceMaterial, m: PhysicsMaterial) {
	s.friction = m.friction
	s.restitution = m.bounciness
	s.userMaterialId = u64(1 + int(m.friction_combine) + int(m.bounce_combine) * 16)
}

// Combines two values with the higher-ranked of the two modes their shapes'
// user material ids carry, the friction modes or the bounce modes.
material_combine :: proc "contextless" (a: f32, id_a: u64, b: f32, id_b: u64, bounce: bool) -> f32 {
	mode :: proc "contextless" (id: u64, bounce: bool) -> Material_Combine {
		if id <= 0 do return .Average
		v := int(id) - 1
		return Material_Combine((v / 16) & 0xf) if bounce else Material_Combine(v & 0xf)
	}
	switch max(mode(id_a, bounce), mode(id_b, bounce)) {
	case .Average:  return (a + b) * 0.5
	case .Minimum:  return min(a, b)
	case .Multiply: return a * b
	case .Maximum:  return max(a, b)
	}
	return (a + b) * 0.5
}

_combine_friction :: proc "c" (a: f32, id_a: u64, b: f32, id_b: u64) -> f32 {
	return material_combine(a, id_a, b, id_b, false)
}

_combine_bounce :: proc "c" (a: f32, id_a: u64, b: f32, id_b: u64) -> f32 {
	return material_combine(a, id_a, b, id_b, true)
}
