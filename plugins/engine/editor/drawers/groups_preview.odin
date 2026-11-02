package drawers

// The Group Names asset in the editor (plugins/engine/docs/Groups.md): the
// open document's names reach the group picker every frame, saved or not, as
// the Render Layers asset's do (layers_preview.odin).

import "moonhug:packages/engine"

@(asset_doc={type=engine.Group_Names})
doc_on_changed_Group_Names :: proc(guid: engine.Asset_GUID, doc: any) {
	engine.group_names_preview(guid, (cast(^engine.Group_Names)doc.data)^)
}
