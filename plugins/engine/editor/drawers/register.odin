package drawers

// Property drawers for engine types the attribute parser cannot name: the
// keys are container typeids ([dynamic]Material_Property), so they register
// here instead of through @(property_drawer), from an @(provider_install)
// proc.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(provider_install)
_register_container_drawers :: proc() {
	inspector.add_property_drawer(typeid_of([dynamic]engine.Material_Property), draw_material_properties)
	inspector.add_property_drawer(typeid_of([dynamic]engine.Material_Texture), draw_material_textures)
	inspector.add_component_wrapper(typeid_of(engine.Material), _material_wrapper)
}

// The material being drawn is the one the property drawers read their shader
// from: property rows for the assigned custom shader come from its reflected
// UBO members, so names are never typed by hand.
@(private = "file")
_material_wrapper :: proc(ctx: ^inspector.Component_Ctx) {
	current_material = cast(^engine.Material)ctx.ptr
	inspector.draw(ctx)
	current_material = nil
}

// A changed material renders live: its values go into the engine's material
// cache, saved or not, after an edit, an undo or a revert. Save persists
// them, unsaved edits revert on the next editor run.
@(asset_doc={type=engine.Material})
on_changed_Material :: proc(guid: engine.Asset_GUID, doc: any) {
	mat := cast(^engine.Material)doc.data
	_ = engine.material_sync_properties(mat)
	engine.material_preview(guid, mat^)
}
