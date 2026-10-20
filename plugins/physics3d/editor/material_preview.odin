package physics3d_editor

// The PhysicsMaterial asset in the editor (physics3d/physics_material.odin): the open
// document's values reach the colliders that use it on the next physics step,
// saved or not. Save persists them, unsaved edits revert on the next editor run.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import physics3d "moonhug:packages/physics3d"

@(provider_install)
_register_physics3d_material_preview :: proc() {
	inspector.add_asset_doc_hook(typeid_of(physics3d.PhysicsMaterial), {
		after = proc(doc: ^inspector.Asset_Doc) {
			physics3d.material_preview(doc.guid, (cast(^physics3d.PhysicsMaterial)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(physics3d.PhysicsMaterial), proc(guid: engine.Asset_GUID, doc: any) {
		physics3d.material_preview(guid, (cast(^physics3d.PhysicsMaterial)doc.data)^)
	})
}
