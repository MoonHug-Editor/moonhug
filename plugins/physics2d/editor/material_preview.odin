package physics2d_editor

// The PhysicsMaterial2D asset in the editor (physics2d/physics_material.odin): the open
// document's values reach the colliders that use it on the next physics step,
// saved or not. Save persists them, unsaved edits revert on the next editor run.

import "moonhug:packages/engine"
import physics2d "moonhug:packages/physics2d"

@(asset_doc={type=physics2d.PhysicsMaterial2D})
doc_on_changed_PhysicsMaterial2D :: proc(guid: engine.Asset_GUID, doc: any) {
	physics2d.material_preview(guid, (cast(^physics2d.PhysicsMaterial2D)doc.data)^)
}
