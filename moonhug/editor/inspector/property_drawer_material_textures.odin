package inspector

// Drawer for Material.textures ([dynamic]Material_Texture): rows are driven
// by the assigned custom shader's reflected samplers past binding 0 (binding
// 0 is Material.texture / the sprite's own texture), in declaration order —
// sampler names become labels, values reuse the standard Asset_GUID picker
// with the image extension filter. No custom shader or a single-sampler
// shader = no UI at all. Registered manually in init() alongside the
// Material_Property drawer.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "../../engine"

draw_material_textures :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	texs := cast(^[dynamic]engine.Material_Texture)ptr

	sr: ^engine.Shader_Runtime
	if current_material != nil && current_material.custom_shader != {} {
		sr, _ = engine.shader_load(current_material.custom_shader)
	}
	if sr == nil || sr.num_samplers <= 1 do return

	im.SeparatorText(label)
	// The picker/drag-drop honor the ext filter global — scope it to these
	// rows (they aren't reached through a tagged struct field).
	prev_filter := current_field_ext_filter
	current_field_ext_filter = "png,jpg,jpeg,bmp"
	defer current_field_ext_filter = prev_filter

	for st in sr.textures {
		if st.binding == 0 do continue
		row: ^engine.Material_Texture
		for &mt in texs {
			if mt.name == st.name {
				row = &mt
				break
			}
		}
		if row == nil do continue // sync adds the row on this frame's end

		name_c := strings.clone_to_cstring(st.name, context.temp_allocator)
		im.PushID(name_c)
		defer im.PopID()
		draw_asset_guid_property(&row.texture, typeid_of(engine.Asset_GUID), name_c)
	}
}
