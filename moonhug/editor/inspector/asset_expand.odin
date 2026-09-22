package inspector

// The `expand` field tag: a reference row that opens its asset's document in
// place. A material slot on a renderer is the case that asked for it — the
// material is what the user is really editing, and a round trip through the
// Project Inspector for every colour tweak is the wrong distance. Any asset
// the inspector can open as a document works the same way, one tag on the
// field, so it is not a material feature.
//
// The foldout draws AFTER the reference row and outside its transaction, so
// the document's rows record against the document (asset owner), never as
// edits of the reference field, and never as prefab overrides on the object
// that holds the reference — an asset edit is not an instance edit.

import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import engine "../../engine"
import "moonhug:editor/widgets"

EXPAND_BTN_W :: f32(24)

// The arrow at the end of the reference row. Open state lives in imgui's
// window storage under the row's id, the way TreeNode keeps its own, so it
// survives reselection and needs no map here. Disabled for an empty slot.
expand_arrow :: proc(guid: engine.Asset_GUID) -> (open: bool) {
	storage := im.GetStateStorage()
	key := im.GetID("##expand")
	open = im.Storage_GetBool(storage, key)
	empty := guid == {}
	if empty do im.BeginDisabled()
	if im.ArrowButton("##expand", open ? .Down : .Right) {
		open = !open
		im.Storage_SetBool(storage, key, open)
	}
	if empty do im.EndDisabled()
	widgets.tooltip(open ? "Collapse the asset" : "Edit the asset here", im.HoveredFlags_AllowWhenDisabled)
	return open && !empty
}

// The referenced document's rows, drawn below the row that expand_arrow
// opened. No header: the row above already names the asset. An edit here
// marks the document dirty, and File/Save writes every dirty document
// (asset_docs_save_dirty), so there is no per-foldout Save either.
draw_expanded_asset :: proc(guid: engine.Asset_GUID) {
	if guid == {} do return
	path, ok := engine.asset_db_get_path(uuid.Identifier(guid))
	if !ok do return
	doc := asset_doc_get(path)
	if doc == nil do return

	im.Indent()
	defer im.Unindent()
	im.PushID("##expand_body")
	defer im.PopID()

	// The document is one asset, not the selected objects: no multi-edit
	// peers, and no prefab host to record overrides on.
	mprev := multi_suspend()
	defer multi_resume(mprev)
	prev_host := engine.inspector_set_nested_host({})
	defer engine.inspector_set_nested_host(prev_host)
	prev_lid := engine.inspector_set_nested_local_id(0)
	defer engine.inspector_set_nested_local_id(prev_lid)
	prev_path := field_edit_set_path("")
	defer field_edit_set_path(prev_path)

	draw_asset_doc(doc)
}
