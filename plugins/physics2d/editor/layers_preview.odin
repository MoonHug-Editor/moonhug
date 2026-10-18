package physics2d_editor

// The Physics 2D Layers asset in the editor (packages/physics2d/layers.odin):
// the open document's names reach the layer picker, and its matrix the
// physics step, every frame, saved or not.
// Save persists them, unsaved edits revert on the next editor run.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import physics2d "moonhug:packages/physics2d"

@(provider_install)
_register_physics2d_layers_preview :: proc() {
	inspector.add_asset_doc_hook(typeid_of(physics2d.Physics2D_Layers), {
		after = proc(doc: ^inspector.Asset_Doc) {
			physics2d.layers_preview(doc.guid, (cast(^physics2d.Physics2D_Layers)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(physics2d.Physics2D_Layers), proc(guid: engine.Asset_GUID, doc: any) {
		physics2d.layers_preview(guid, (cast(^physics2d.Physics2D_Layers)doc.data)^)
	})
}
