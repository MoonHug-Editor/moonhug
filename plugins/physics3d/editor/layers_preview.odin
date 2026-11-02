package physics3d_editor

// The Physics 3D Layers asset in the editor (packages/physics3d/layers.odin):
// the open document's names reach the layer picker, and its matrix the
// physics step, every frame, saved or not.
// Save persists them, unsaved edits revert on the next editor run.

import "moonhug:packages/engine"
import physics3d "moonhug:packages/physics3d"

@(asset_doc={type=physics3d.Physics3D_Layers})
doc_on_changed_Physics3D_Layers :: proc(guid: engine.Asset_GUID, doc: any) {
	physics3d.layers_preview(guid, (cast(^physics3d.Physics3D_Layers)doc.data)^)
}
