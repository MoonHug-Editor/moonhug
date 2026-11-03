package drawers

// The material inspector's step and its live preview.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"

// The material being drawn is the one the property drawers read their shader
// from: property rows for the assigned custom shader come from its reflected
// UBO members, so names are never typed by hand.
@(property_drawer={type=engine.Material, order="middle"})
property_drawer_Material_shader_context :: proc(ctx: ^inspector.Ctx) {
	current_material = cast(^engine.Material)ctx.ptr
	inspector.draw(ctx)
	current_material = nil
}

// A changed material renders live: its values go into the engine's material
// cache, saved or not, after an edit, an undo or a revert. Save persists
// them, unsaved edits revert on the next editor run.
@(doc_on_changed={type=engine.Material})
doc_on_changed_Material :: proc(guid: engine.Asset_GUID, doc: any) {
	mat := cast(^engine.Material)doc.data
	_ = engine.material_sync_properties(mat)
	engine.material_preview(guid, mat^)
}
