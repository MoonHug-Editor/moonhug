package drawers

// The editor half of a scene file's sub-assets
// (plugins/engine/scene_sub_assets.odin): the sub-asset provider of `.scene`
// files. A scene file unfolds to its sub-assets in the Project window, a
// reference field of the scene's objects picks among them, and the inspector
// edits each one as a document, read from and stored in the scene's records.

import "base:runtime"
import "core:fmt"
import "moonhug:editor/subassets"
import ser "moonhug:libs/serialization"
import "moonhug:packages/engine"
import scene_undo "moonhug:packages/engine/editor/undo"

@(provider_install)
scene_sub_assets_install :: proc() {
	provider := subassets.Provider{
		list     = _scene_sub_assets,
		text     = engine.scene_sub_asset_text,
		load     = _scene_sub_asset_load,
		store    = _scene_sub_asset_store,
		save     = _scene_sub_asset_save,
		editable = _scene_sub_assets_editable,
		create   = _scene_sub_asset_create,
		rename   = _scene_sub_asset_rename,
		remove   = _scene_sub_asset_remove,
	}
	subassets.register(".scene", provider)
	// A scene never saved has no path: its sub-assets are those of the
	// empty guid.
	subassets.register(subassets.NO_FILE, provider)
}

// A scene file's sub-assets. Each one's kind is its asset type, which is
// what a reference field's `ext:` tag matches. An empty path: those of the
// scenes never saved.
@(private = "file")
_scene_sub_assets :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	owner: engine.Asset_GUID
	if path != "" {
		guid, ok := engine.asset_db_get_guid(path)
		if !ok do return nil
		owner = engine.Asset_GUID(guid)
	}
	list := engine.scene_sub_assets(owner, context.temp_allocator)
	if len(list) == 0 do return nil
	out := make([]subassets.Sub_Asset, len(list), allocator)
	for a, i in list {
		name := a.name
		if name == "" do name = fmt.aprintf("%s %d", a.type, a.local_id, allocator = allocator)
		out[i] = subassets.Sub_Asset{id = a.local_id, name = name, kind = a.type}
	}
	return out
}

// A record's text as a document: a reference to another record of the same
// file holds no guid in the text and the file's guid in the document.
@(private = "file")
_scene_sub_asset_load :: proc(ref: engine.PPtr, text: string) -> (any, bool) {
	engine.asset_parse_begin(engine.asset_key(ref))
	defer engine.asset_parse_end()
	return ser.load_from_bytes(transmute([]byte)text)
}

// The document as its record's text, written to its scene.
@(private = "file")
_scene_sub_asset_store :: proc(ref: engine.PPtr, data: any) -> bool {
	engine.asset_write_begin(engine.asset_key(ref))
	text, ok := ser.save_to_text(data)
	engine.asset_write_end()
	if !ok do return false
	return engine.scene_sub_asset_store(ref, text)
}

// The document as its record's text, written into the file of a scene that
// is not open.
@(private = "file")
_scene_sub_asset_save :: proc(ref: engine.PPtr, data: any) -> bool {
	engine.asset_write_begin(engine.asset_key(ref))
	text, ok := ser.save_to_text(data)
	engine.asset_write_end()
	if !ok do return false
	return engine.scene_sub_asset_store_file(ref, text)
}

// Whether the scene is open: an edit of its sub-assets then goes into the
// scene and is an undo step. Otherwise it goes into the scene's file.
@(private = "file")
_scene_sub_assets_editable :: proc(guid: engine.Asset_GUID) -> bool {
	return engine.scene_sub_asset_owner_scene(guid) != nil
}

// The instance as a record's text, its references to the file's other
// sub-assets written without the file's guid.
@(private = "file")
_record_text :: proc(owner: engine.Asset_GUID, data: any) -> (text: string, ok: bool) {
	engine.asset_write_begin_in(owner)
	defer engine.asset_write_end()
	return ser.save_to_text(data)
}

@(private = "file")
_scene_sub_asset_create :: proc(owner: engine.Asset_GUID, kind, name: string, data: any) -> (ref: engine.PPtr, ok: bool) {
	if s := engine.scene_sub_asset_owner_scene(owner); s != nil {
		text := _record_text(s.asset_guid, data) or_return
		return scene_undo.sub_asset_create(s, kind, name, text)
	}
	if engine.asset_guid_is_empty(owner) do return
	text := _record_text(owner, data) or_return
	return engine.scene_sub_asset_add_file(owner, kind, name, text)
}

@(private = "file")
_scene_sub_asset_rename :: proc(ref: engine.PPtr, name: string) -> bool {
	if s := engine.scene_sub_asset_scene(ref); s != nil do return scene_undo.sub_asset_rename(s, ref.local_id, name)
	return engine.scene_sub_asset_rename_file(ref, name)
}

@(private = "file")
_scene_sub_asset_remove :: proc(ref: engine.PPtr) -> bool {
	if s := engine.scene_sub_asset_scene(ref); s != nil do return scene_undo.sub_asset_remove(s, ref.local_id)
	return engine.scene_sub_asset_remove_file(ref)
}
