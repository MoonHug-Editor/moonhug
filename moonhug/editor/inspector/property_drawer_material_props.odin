package inspector

// Drawer for Material.properties ([dynamic]Material_Property): rows are
// driven by the assigned custom shader's reflected members, in declaration
// order — names become read-only labels, values get widgets sized to the
// member type (float → one drag; vec2/vec3 likewise; vec4 → color picker
// when the name contains "color", drags otherwise). Rows that don't match a
// shader member aren't drawn (material_sync_properties removes them anyway);
// no custom shader = no properties UI at all. Registered manually in init()
// — the drawer map is consulted before the generic array UI, so this
// replaces the raw name+vec4 rows for exactly this field type.

import "core:strings"
import im "../../../external/odin-imgui"
import "../../engine"

// The Material whose fields the project inspector is currently drawing
// (set around draw_inspector in _draw_asset_inspector) — lets this drawer
// reach the sibling custom_shader field from inside the properties field.
current_material: ^engine.Material

draw_material_properties :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	props := cast(^[dynamic]engine.Material_Property)ptr

	sr: ^engine.Shader_Runtime
	if current_material != nil && current_material.custom_shader != {} {
		sr, _ = engine.shader_load(current_material.custom_shader)
	}
	if sr == nil || len(sr.properties) == 0 do return

	im.SeparatorText(label)
	for sp in sr.properties {
		prop: ^engine.Material_Property
		for &mp in props {
			if mp.name == sp.name {
				prop = &mp
				break
			}
		}
		if prop == nil do continue // sync adds the row on this frame's end

		name_c := strings.clone_to_cstring(sp.name, context.temp_allocator)
		im.PushID(name_c)
		defer im.PopID()

		changed := false
		switch sp.size {
		case 4:
			changed = im.DragFloat(name_c, &prop.value.x, 0.01, format = "%g")
		case 8:
			changed = im.DragFloat2(name_c, cast(^[2]f32)&prop.value, 0.01, format = "%g")
		case 12:
			changed = im.DragFloat3(name_c, cast(^[3]f32)&prop.value, 0.01, format = "%g")
		case:
			if strings.contains(sp.name, "color") || strings.contains(sp.name, "colour") {
				changed = im.ColorEdit4(name_c, &prop.value)
			} else {
				changed = im.DragFloat4(name_c, &prop.value, 0.01, format = "%g")
			}
		}
		if changed do mark_inspector_changed()
	}
}
