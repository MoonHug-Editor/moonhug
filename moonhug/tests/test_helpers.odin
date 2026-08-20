package tests

import "../engine"

import "core:encoding/json"
import "core:strings"

// Shared helpers used by multiple test files. Keep procs small and parameterised
// so each test file can stay focused on assertions rather than pool walking.

find_transform_named :: proc(
	w: ^engine.World,
	s: ^engine.Scene,
	name: string,
	nested_owned: bool,
) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene != s || tr.nested_owned != nested_owned do continue
		if strings.compare(tr.name, name) != 0 do continue
		th := h
		th.type_key = .Transform
		return engine.Transform_Handle(th)
	}
	return {}
}

find_nested_named_under_host :: proc(
	w: ^engine.World,
	s: ^engine.Scene,
	host: engine.Transform_Handle,
	name: string,
) -> engine.Transform_Handle {
	it := engine.pool_iterator(&w.transforms)
	for tr, h in engine.pool_next(&it) {
		if tr.scene != s || !tr.nested_owned do continue
		if strings.compare(tr.name, name) != 0 do continue
		th := h
		th.type_key = .Transform
		tH := engine.Transform_Handle(th)
		if engine.transform_find_nested_host(tH) == host {
			return tH
		}
	}
	return {}
}

hierarchy_shows_nested_scene_suffix :: proc(w: ^engine.World, tH: engine.Transform_Handle) -> bool {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil || t.scene == nil do return false
	return engine.scene_hierarchy_transform_is_nested_scene_host(t.scene, tH)
}

json_f32 :: proc(v: json.Value) -> (f32, bool) {
	#partial switch n in v {
	case json.Float:   return f32(n), true
	case json.Integer: return f32(n), true
	}
	return 0, false
}

override_vec3_matches :: proc(v: json.Value, want: [3]f32) -> bool {
	arr, ok := v.(json.Array)
	if !ok || len(arr) < 3 do return false
	x, x_ok := json_f32(arr[0])
	y, y_ok := json_f32(arr[1])
	z, z_ok := json_f32(arr[2])
	if !x_ok || !y_ok || !z_ok do return false
	return x == want[0] && y == want[1] && z == want[2]
}
