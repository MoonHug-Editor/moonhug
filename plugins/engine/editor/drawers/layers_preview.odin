package drawers

// The Render Layers asset in the editor (plugins/engine/docs/Layers.md): the
// open document's names reach the layer picker every frame, saved or not. Save persists them, unsaved edits revert
// on the next editor run. An undo or a revert while another asset is shown
// reaches the picker through the document preview.

import "moonhug:packages/engine"

@(asset_doc={type=engine.Render_Layers})
on_changed_Render_Layers :: proc(guid: engine.Asset_GUID, doc: any) {
	engine.render_layers_preview(guid, (cast(^engine.Render_Layers)doc.data)^)
}
