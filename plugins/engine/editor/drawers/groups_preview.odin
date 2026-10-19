package drawers

// The Group Names asset in the editor (plugins/engine/docs/Groups.md): the
// open document's names reach the group picker every frame, saved or not, as
// the Render Layers asset's do (layers_preview.odin).

import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(provider_install)
_register_groups_preview :: proc() {
	inspector.add_asset_doc_hook(typeid_of(engine.Group_Names), {
		after = proc(doc: ^inspector.Asset_Doc) {
			engine.group_names_preview(doc.guid, (cast(^engine.Group_Names)doc.data.data)^)
		},
	})
	inspector.doc_preview_register(typeid_of(engine.Group_Names), proc(guid: engine.Asset_GUID, doc: any) {
		engine.group_names_preview(guid, (cast(^engine.Group_Names)doc.data)^)
	})
}
