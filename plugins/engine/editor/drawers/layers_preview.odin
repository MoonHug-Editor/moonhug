package drawers

// The Render Layers asset in the editor (plugins/engine/docs/Layers.md): the
// open document's names reach the layer picker every frame, saved or not. Save persists them, unsaved edits revert
// on the next editor run. An undo or a revert while another asset is shown
// reaches the picker through the document preview.

import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(provider_install)
_register_layers_preview :: proc() {
	inspector.add_asset_doc_hook(typeid_of(engine.Render_Layers), {
		after = proc(doc: ^inspector.Asset_Doc) {
			engine.render_layers_preview(doc.guid, (cast(^engine.Render_Layers)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(engine.Render_Layers), proc(guid: engine.Asset_GUID, doc: any) {
		engine.render_layers_preview(guid, (cast(^engine.Render_Layers)doc.data)^)
	})
}
