package physics3d_editor

// The PhysicsMaterial asset in the editor (physics3d/physics_material.odin): the open
// document's values reach the colliders that use it on the next physics step,
// saved or not. Save persists them, unsaved edits revert on the next editor run.

import "moonhug:packages/engine"
import physics3d "moonhug:packages/physics3d"

@(asset_doc={type=physics3d.PhysicsMaterial})
doc_on_changed_PhysicsMaterial :: proc(guid: engine.Asset_GUID, doc: any) {
	physics3d.material_preview(guid, (cast(^physics3d.PhysicsMaterial)doc.data)^)
}
