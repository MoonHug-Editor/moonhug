package physics2d_editor

// The PhysicsMaterial2D asset in the editor (physics2d/physics_material.odin): the open
// document's values reach the colliders that use it on the next physics step,
// saved or not. Save persists them, unsaved edits revert on the next editor run.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import physics2d "moonhug:packages/physics2d"

@(provider_install)
_register_physics2d_material_preview :: proc() {
	inspector.add_asset_doc_hook(typeid_of(physics2d.PhysicsMaterial2D), {
		after = proc(doc: ^inspector.Asset_Doc) {
			physics2d.material_preview(doc.guid, (cast(^physics2d.PhysicsMaterial2D)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(physics2d.PhysicsMaterial2D), proc(guid: engine.Asset_GUID, doc: any) {
		physics2d.material_preview(guid, (cast(^physics2d.PhysicsMaterial2D)doc.data)^)
	})
}
