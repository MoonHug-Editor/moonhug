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
}

// The open .mat document is the material the property drawers read their
// shader from, and its edits render live: the values go into the engine's
// material cache every frame, saved or not. Save persists them, unsaved edits
// revert on the next editor run. Property rows for the assigned custom shader
// come from its reflected UBO members, so names are never typed by hand.
@(provider_install)
_register_material_doc_hook :: proc() {
	inspector.add_asset_doc_hook(typeid_of(engine.Material), {
		before = proc(doc: ^inspector.Asset_Doc) { current_material = cast(^engine.Material)doc.data.data },
		after = proc(doc: ^inspector.Asset_Doc) {
			mat := cast(^engine.Material)doc.data.data
			_ = engine.material_sync_properties(mat)
			engine.material_preview(doc.guid, mat^)
			current_material = nil
		},
	})
	register_material_doc_preview()
}

// A material undone or reverted while another asset is shown reaches the
// cache too.
register_material_doc_preview :: proc() {
	inspector.doc_preview_register(typeid_of(engine.Material), proc(guid: engine.Asset_GUID, doc: any) {
		mat := cast(^engine.Material)doc.data
		_ = engine.material_sync_properties(mat)
		engine.material_preview(guid, mat^)
	})
}
