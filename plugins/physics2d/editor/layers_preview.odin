package physics2d_editor

// The Physics 2D Layers asset in the editor (packages/physics2d/layers.odin):
// the open document's names reach the layer picker, and its matrix the
// physics step, every frame, saved or not.
// Save persists them, unsaved edits revert on the next editor run.

import "moonhug:packages/engine"
import physics2d "moonhug:packages/physics2d"

@(asset_doc={type=physics2d.Physics2D_Layers})
doc_on_changed_Physics2D_Layers :: proc(guid: engine.Asset_GUID, doc: any) {
	physics2d.layers_preview(guid, (cast(^physics2d.Physics2D_Layers)doc.data)^)
}
