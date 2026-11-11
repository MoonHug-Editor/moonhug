package engine

// A scene file's sub-assets: assets that live inside a scene file, not in a
// file of their own. A material used by one object, a noise map used by one
// material. They are authored, where a model's sub-assets are derived by its
// importer: the scene file is the only place their data is.
//
//   - A scene file holds a list of records, `assets`: each a local id, the
//     asset's type (spelled like a file extension without the dot: "mat")
//     and its data, the JSON the asset's own file would hold.
//   - A reference to one is what a reference to any sub-asset is:
//     PPtr{the file's guid, the record's local id}. In the file itself the
//     guid is written empty, "this file", so a copy of the file refers to
//     its own records. The reference holds the file's guid in memory: it is
//     bound when it is read (the file is known then) and unbound when its
//     scene is written.
//   - A nested prefab's records stay in the prefab's file. Its objects'
//     references name that file, and every instance shares the one asset.
//     An override in the host may name a record of the host.
//   - asset_key turns any reference into a 16-byte key: the guid for a whole
//     asset, a hash of the pair for a sub-asset. Caches keyed by guid (the
//     material cache, the renderer) take that key and need no change.
//   - asset_source gives a loader the data a key names, from a file or from
//     a scene's record. A loader that reads through it loads both.
//
// The records of an open scene are on the Scene (Scene.assets), which is what
// its save writes. This file's table is what references resolve against: an
// open scene's records as they are now, and the records of any other scene
// file, read from its bytes on first use (scene_lib).

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:libs/serialization"

// One sub-asset of a scene file.
Scene_Sub_Asset :: struct {
	local_id: Local_ID,
	type:     string, // owned: "mat", "noise"
	name:     string `json:"name,omitempty"`, // owned: what the editor lists it as
	data:     json.Value, // owned: what the asset's own file would hold
}

// One sub-asset of a scene file as a list shows it. The strings are on the
// allocator the list was asked with.
Scene_Sub_Asset_Info :: struct {
	local_id: Local_ID,
	type:     string,
	name:     string,
}

@(private = "file")
_Record :: struct {
	type: string, // owned
	name: string, // owned
	text: string, // owned: the data as JSON text, what a loader parses
}

@(private = "file")
_Owner :: struct {
	loaded:  bool, // its file was read, or its scene gave its records
	records: map[Local_ID]_Record,
}

// By owning file's guid. The empty guid owns the records of scenes never
// saved: local ids are random, so they do not meet. Default allocator.
@(private = "file")
_owners: map[Asset_GUID]^_Owner

// The files a reference read now may point into: the file being loaded, the
// bases of that file when it is a variant, then the scene it loads into.
// Default allocator.
@(private = "file")
_bind_owners: [dynamic]Asset_GUID
@(private = "file")
_binding: bool

// A variant's base, by the variant's guid. A nested variant loads from
// flattened bytes that hold its base's content (_prefab_resolved_bytes), and
// that content's references name records of the base's file. Set by the
// flattening. Default allocator.
@(private = "file")
_variant_bases: map[Asset_GUID]Asset_GUID

// The file being written: references into it are written with an empty guid.
@(private = "file")
_unbind_owner: Asset_GUID
@(private = "file")
_unbinding: bool

@(init)
_scene_sub_assets_init :: proc "contextless" () {
	context = runtime.default_context()
	_owners = make(map[Asset_GUID]^_Owner, runtime.default_allocator())
	serialization.pptr_read_hook = _this_file_read_hook
	serialization.pptr_write_hook = _this_file_write_hook
	serialization.pptr_embedded_write = _embedded_write
	serialization.pptr_embedded_read = _embedded_read
}

// --- Keys --------------------------------------------------------------------

// One 16-byte key for any reference (libs/core/asset_key.odin).
asset_key :: core.asset_key
asset_keys :: core.asset_keys
asset_key_ref :: core.asset_key_ref

// --- Reading -----------------------------------------------------------------

// The data the key names and its type (a file extension without the dot): a
// scene record's JSON, or the bytes of the asset's file. On `allocator`.
asset_source :: proc(key: Asset_GUID, allocator := context.temp_allocator) -> (data: []u8, type: string, ok: bool) {
	if ref, sub := asset_key_ref(key); sub {
		rec, has := _record(ref.guid, ref.local_id)
		if !has do return nil, "", false
		return transmute([]u8)strings.clone(rec.text, allocator), rec.type, true
	}
	path, path_ok := asset_db_get_path(uuid.Identifier(key))
	if !path_ok do return nil, "", false
	bytes, err := os.read_entire_file(path, allocator)
	if err != nil do return nil, "", false
	ext := filepath.ext(path)
	if len(ext) > 0 do ext = ext[1:]
	return bytes, ext, true
}

// The type of the asset the key names, a file extension in lower case
// without the dot ("mat", "png"), "" for an unknown key. A scene record's
// type, or its file's extension.
asset_type :: proc(key: Asset_GUID) -> string {
	if ref, sub := asset_key_ref(key); sub do return scene_sub_asset_type(ref)
	path, ok := asset_db_get_path(uuid.Identifier(key))
	if !ok do return ""
	ext := filepath.ext(path)
	if len(ext) > 0 do ext = ext[1:]
	return strings.to_lower(ext, context.temp_allocator)
}

// The sub-assets of the scene file `owner`, sorted by local id. On `allocator`.
scene_sub_assets :: proc(owner: Asset_GUID, allocator := context.temp_allocator) -> []Scene_Sub_Asset_Info {
	// A scene file's list is the asset database's (asset_db_sub_assets): no
	// file is read to list. Scenes never saved have no file, and are listed
	// from the table.
	if !asset_guid_is_empty(owner) {
		known := assets.asset_db_sub_assets(owner)
		list := make([]Scene_Sub_Asset_Info, len(known), allocator)
		// Copies: the database frees its strings when the list is set again,
		// which a rename does in the middle of the frame that lists them.
		for e, i in known do list[i] = Scene_Sub_Asset_Info{local_id = e.id, type = strings.clone(e.kind, allocator), name = strings.clone(e.name, allocator)}
		return list
	}
	o := _owner(owner)
	out := make([dynamic]Scene_Sub_Asset_Info, 0, len(o.records), allocator)
	for id, rec in o.records do append(&out, Scene_Sub_Asset_Info{local_id = id, type = strings.clone(rec.type, allocator), name = strings.clone(rec.name, allocator)})
	slice.sort_by(out[:], proc(a, b: Scene_Sub_Asset_Info) -> bool { return a.local_id < b.local_id })
	return out[:]
}

// The JSON text of the scene sub-asset `ref` names, false for none.
scene_sub_asset_text :: proc(ref: PPtr) -> (text: string, ok: bool) {
	rec := _record(ref.guid, ref.local_id) or_return
	return rec.text, true
}

// Writes new data for the scene sub-asset `ref` names: the editor's edit.
// Its scene has to be open, and is marked edited. The caches that hold what
// the old data made let go of it.
scene_sub_asset_store :: proc(ref: PPtr, data_json: string) -> bool {
	s := scene_sub_asset_scene(ref)
	if s == nil do return false
	scene_sub_asset_set(s, ref.local_id, data_json) or_return
	s.dirty = true
	// A texture made from the record is made again on next use. A material
	// is pushed by its document (doc_on_changed_Material).
	texture_unload(asset_key(ref))
	return true
}

// --- Embedded assets ------------------------------------------------------------
//
// An embedded asset is used by one field and stored inside it: where a scene
// or an asset file would hold a reference, it holds the asset's data. It has
// no place in the Project window and no reference another field could hold.
//
//   - In memory the field holds {EMBEDDED_ASSETS, id}, and the data is a record
//     under that owner in the table above, so a loader reads it like any
//     sub-asset.
//   - Reading a file makes a record with a new id for each embedded asset, and
//     writing puts each record's data back in its field. A copy of an object
//     that goes through its text has embedded assets of its own.
//   - An undo snapshot also holds the id (serialization.pptr_embedded_ids):
//     a step put back gives the field the record it had, with the data of
//     the snapshot.
//   - The ids last for the session and the records until exit: the data is
//     small text, and nothing tracks which field still uses one.
//   - What holds the field (a scene, an asset) is the editor's to know: an
//     edit marks it edited there, not here.
//   - A reference inside the data names its file by guid. The "this file"
//     form of a scene's own sub-assets is not used inside embedded data.

@(private = "file")
_embedded_next: Local_ID

// Makes an embedded asset of `type` ("mat", "noise") from its data as JSON
// text. The reference goes into the one field that uses it.
embedded_asset_add :: proc(type, data_json: string) -> (ref: PPtr, ok: bool) {
	context.allocator = runtime.default_allocator()
	data, err := json.parse_string(data_json, .JSON, true, context.temp_allocator)
	if err != nil do return {}, false
	o := _owner(core.EMBEDDED_ASSETS)
	o.loaded = true
	_embedded_next += 1
	_record_set(o, _embedded_next, type, "", data)
	return PPtr{guid = core.EMBEDDED_ASSETS, local_id = _embedded_next}, true
}

// Replaces the data of the embedded asset `ref`: the editor's edit.
embedded_asset_store :: proc(ref: PPtr, data_json: string) -> bool {
	if ref.guid != core.EMBEDDED_ASSETS do return false
	o := _owner(core.EMBEDDED_ASSETS)
	old, has := o.records[ref.local_id]
	if !has do return false
	data, err := json.parse_string(data_json, .JSON, true, context.temp_allocator)
	if err != nil do return false
	type := strings.clone(old.type, context.temp_allocator)
	_record_set(o, ref.local_id, type, "", data)
	texture_unload(asset_key(ref))
	return true
}

// Every embedded asset of the session, for the editor's lookups. On `allocator`.
embedded_assets :: proc(allocator := context.temp_allocator) -> []Scene_Sub_Asset_Info {
	o := _owner(core.EMBEDDED_ASSETS)
	out := make([dynamic]Scene_Sub_Asset_Info, 0, len(o.records), allocator)
	for id, rec in o.records do append(&out, Scene_Sub_Asset_Info{local_id = id, type = strings.clone(rec.type, allocator), name = ""})
	return out[:]
}

@(private = "file")
_embedded_write :: proc(p: PPtr) -> (type: string, data_json: string, ok: bool) {
	if p.guid != core.EMBEDDED_ASSETS do return
	rec, has := _owner(core.EMBEDDED_ASSETS).records[p.local_id]
	if !has do return
	return rec.type, rec.text, true
}

// The record `id` names when it is still there with the same type: an undo
// step put back. A new one otherwise.
@(private = "file")
_embedded_read :: proc(type: string, data_json: string, id: Local_ID) -> PPtr {
	if id != 0 {
		ref := PPtr{guid = core.EMBEDDED_ASSETS, local_id = id}
		rec, has := _owner(core.EMBEDDED_ASSETS).records[id]
		if has && rec.type == type && embedded_asset_store(ref, data_json) do return ref
	}
	ref, _ := embedded_asset_add(type, data_json)
	return ref
}

// --- The sub-assets of a scene file that is not open --------------------------
//
// A sub-asset is edited, added, renamed and removed without its scene open:
// the change goes into the file. The file is read as a SceneFile, the one
// record is changed, and the rest is written as a save writes it
// (scene_file_bytes). The caches follow as they follow a save: the cached
// bytes of the file, the table, a texture made from the record, the asset
// database's list. Instances of the file in open scenes stay as they are:
// they name a sub-asset, they do not hold it. These are file operations, as
// a change of any closed file is: no undo step records them.

// Writes new data for the sub-asset `ref` names.
scene_sub_asset_store_file :: proc(ref: PPtr, data_json: string) -> bool {
	_, ok := _scene_file_sub_asset_op(ref.guid, {kind = .Set_Data, local_id = ref.local_id, data_json = data_json})
	return ok
}

// Adds a sub-asset of `type` to the scene file `owner`. Its local id is one
// nothing in the file has.
scene_sub_asset_add_file :: proc(owner: Asset_GUID, type, name, data_json: string) -> (ref: PPtr, ok: bool) {
	id := _scene_file_sub_asset_op(owner, {kind = .Add, type = type, name = name, data_json = data_json}) or_return
	return PPtr{guid = owner, local_id = id}, true
}

scene_sub_asset_rename_file :: proc(ref: PPtr, name: string) -> bool {
	_, ok := _scene_file_sub_asset_op(ref.guid, {kind = .Rename, local_id = ref.local_id, name = name})
	return ok
}

// A reference to a removed sub-asset stays where it is and shows as missing.
scene_sub_asset_remove_file :: proc(ref: PPtr) -> bool {
	_, ok := _scene_file_sub_asset_op(ref.guid, {kind = .Remove, local_id = ref.local_id})
	return ok
}

@(private = "file")
_File_Op :: struct {
	kind:      enum {
		Set_Data,
		Add,
		Rename,
		Remove,
	},
	local_id:  Local_ID,
	type:      string,
	name:      string,
	data_json: string,
}

// Applies `op` to the records of the scene file `owner` and writes the file.
// Returns the local id of the record it changed or added.
@(private = "file")
_scene_file_sub_asset_op :: proc(owner: Asset_GUID, op: _File_Op) -> (local_id: Local_ID, ok: bool) {
	path := asset_db_get_path(uuid.Identifier(owner)) or_return
	bytes, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil do return
	sf: SceneFile
	if scene_file_unmarshal(bytes, &sf) != nil do return
	defer scene_file_destroy(&sf)

	// What the file owns is freed by scene_file_destroy on this allocator.
	data: json.Value
	if op.kind == .Set_Data || op.kind == .Add {
		parsed, err := json.parse_string(op.data_json, .JSON, true)
		if err != nil do return
		data = parsed
	}
	local_id = op.local_id
	at := -1
	for a, i in sf.assets do if a.local_id == op.local_id do at = i
	switch op.kind {
	case .Set_Data:
		if at < 0 {
			json.destroy_value(data)
			return 0, false
		}
		json.destroy_value(sf.assets[at].data)
		sf.assets[at].data = data
	case .Add:
		local_id = _scene_file_new_lid(&sf)
		append(&sf.assets, Scene_Sub_Asset{local_id = local_id, type = strings.clone(op.type), name = strings.clone(op.name), data = data})
	case .Rename:
		if at < 0 do return 0, false
		delete(sf.assets[at].name)
		sf.assets[at].name = strings.clone(op.name)
	case .Remove:
		if at < 0 do return 0, false
		gone := sf.assets[at]
		ordered_remove(&sf.assets, at)
		delete(gone.type)
		delete(gone.name)
		json.destroy_value(gone.data)
	}

	out := scene_file_bytes(&sf) or_return
	defer delete(out)
	if write_err := os.write_entire_file(path, out); write_err != nil {
		fmt.printf("[Scene] Failed to write file: %s — %v\n", path, write_err)
		return 0, false
	}
	_prefab_bytes_refresh(owner, out)
	scene_sub_assets_drop(owner)
	texture_unload(asset_key(PPtr{guid = owner, local_id = local_id}))
	// The asset database's list follows from the refresh: the file changed.
	if assets.asset_db.root_path != "" do asset_db_request_refresh()
	return local_id, true
}

// A local id nothing in the scene file has: its objects, their components,
// its nested scene records, its breadcrumbs and its sub-assets share one
// space of ids.
@(private = "file")
_scene_file_new_lid :: proc(sf: ^SceneFile) -> Local_ID {
	taken := make(map[Local_ID]bool, context.temp_allocator)
	for t in sf.transforms {
		taken[t.local_id] = true
		for c in t.components do taken[c.local_id] = true
	}
	for ns in sf.nested_scenes do taken[ns.local_id] = true
	for bc in sf.breadcrumbs do taken[bc.local_id] = true
	for a in sf.assets do taken[a.local_id] = true
	for {
		id := Local_ID(rand.uint64()) & AUTHORED_LID_MASK
		if id != 0 && !taken[id] do return id
	}
}

// --- The asset database's list ----------------------------------------------
//
// The database knows each scene file's sub-assets (assets.asset_db_sub_assets),
// so a picker or a Project row lists them without reading a file. The scene
// indexer sets a file's list from its bytes. While a scene is open its own
// records are the truth, edits not yet saved included: every change of them
// sets the list again, and the indexer leaves an open scene's list alone.

// From the scene's records. Nothing for a scene never saved: it has no file.
@(private)
_scene_sub_assets_index_scene :: proc(s: ^Scene) {
	if s == nil || asset_guid_is_empty(s.asset_guid) do return
	// A game lists nothing: the list is for the editor's pickers and rows.
	if assets.asset_db.pipeline == .Catalog do return
	list := make([]assets.Asset_Sub_Info, len(s.assets), context.temp_allocator)
	for a, i in s.assets do list[i] = {id = a.local_id, name = a.name, kind = a.type}
	assets.asset_db_sub_assets_set(s.asset_guid, list)
}

// From a parsed scene file, for the indexer.
@(private)
_scene_sub_assets_index_file :: proc(guid: Asset_GUID, sf: ^SceneFile) {
	// A refresh can run with no world set up yet (the first scan at startup):
	// no scene is open then.
	if ctx_get() != nil {
		if s := sm_scene_find_by_guid(guid); s != nil {
			_scene_sub_assets_index_scene(s)
			return
		}
	}
	list := make([]assets.Asset_Sub_Info, len(sf.assets), context.temp_allocator)
	for a, i in sf.assets do list[i] = {id = a.local_id, name = a.name, kind = a.type}
	assets.asset_db_sub_assets_set(guid, list)
}

// From the file's records in the table, for a scene closed with edits it
// did not save: the list goes back to what the file holds.
@(private = "file")
_scene_sub_assets_index_records :: proc(guid: Asset_GUID) {
	o := _owner(guid)
	if !o.loaded do _owner_read_file(guid, o)
	list := make([dynamic]assets.Asset_Sub_Info, 0, len(o.records), context.temp_allocator)
	for id, rec in o.records do append(&list, assets.Asset_Sub_Info{id = id, name = rec.name, kind = rec.type})
	slice.sort_by(list[:], proc(a, b: assets.Asset_Sub_Info) -> bool { return a.id < b.id })
	assets.asset_db_sub_assets_set(guid, list[:])
}

// The open scene that owns the sub-asset `ref` names, nil for none.
scene_sub_asset_scene :: proc(ref: PPtr) -> ^Scene {
	if s := sm_scene_find_by_guid(ref.guid); s != nil do return s
	if !asset_guid_is_empty(ref.guid) do return nil
	// A scene never saved has no guid: the one that holds the record.
	sm := ctx_scene_manager()
	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if s == nil || !sm_scene_is_valid(s) do continue
		for a in s.assets do if a.local_id == ref.local_id do return s
	}
	return nil
}

// The open scene whose file is `owner`, nil for none. The empty guid names a
// scene never saved: the active scene when it is one, else the first.
scene_sub_asset_owner_scene :: proc(owner: Asset_GUID) -> ^Scene {
	if !asset_guid_is_empty(owner) do return sm_scene_find_by_guid(owner)
	if active := sm_scene_get_active(); active != nil && asset_guid_is_empty(active.asset_guid) do return active
	sm := ctx_scene_manager()
	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if s != nil && sm_scene_is_valid(s) && asset_guid_is_empty(s.asset_guid) do return s
	}
	return nil
}

// Whether the scene file `owner` holds a sub-asset under `local_id`.
scene_sub_asset_has :: proc(owner: Asset_GUID, local_id: Local_ID) -> bool {
	_, has := _record(owner, local_id)
	return has
}

// The type of the scene sub-asset `ref` names, "" for none.
scene_sub_asset_type :: proc(ref: PPtr) -> string {
	rec, _ := _record(ref.guid, ref.local_id)
	return rec.type
}

@(private = "file")
_record :: proc(owner: Asset_GUID, local_id: Local_ID) -> (_Record, bool) {
	if local_id == 0 do return {}, false
	o := _owner(owner)
	if !o.loaded do _owner_read_file(owner, o)
	rec, has := o.records[local_id]
	return rec, has
}

@(private = "file")
_owner :: proc(owner: Asset_GUID) -> ^_Owner {
	if o, has := _owners[owner]; has do return o
	context.allocator = runtime.default_allocator()
	o := new(_Owner)
	_owners[owner] = o
	return o
}

// Reads the records of a scene file that is not open, from its bytes.
@(private = "file")
_owner_read_file :: proc(owner: Asset_GUID, o: ^_Owner) {
	o.loaded = true
	if asset_guid_is_empty(owner) || !scene_lib_register(owner) do return
	bytes := scene_lib[owner]
	// Most scene files have none: the text says so without a parse.
	if !strings.contains(string(bytes), `"assets"`) do return
	root, err := json.parse(bytes, .JSON, true, context.temp_allocator)
	if err != nil do return
	obj, _ := root.(json.Object)
	list, _ := obj["assets"].(json.Array)
	for item in list {
		rec, is_obj := item.(json.Object)
		if !is_obj do continue
		id: Local_ID
		#partial switch n in rec["local_id"] {
		case json.Integer: id = Local_ID(n)
		case json.Float:   id = Local_ID(n)
		}
		type, _ := rec["type"].(json.String)
		name, _ := rec["name"].(json.String)
		if id == 0 || type == "" do continue
		_record_set(o, id, string(type), string(name), rec["data"])
	}
}

@(private = "file")
_record_set :: proc(o: ^_Owner, local_id: Local_ID, type, name: string, data: json.Value) {
	context.allocator = runtime.default_allocator()
	text, err := json.marshal(data, {spec = .JSON, sort_maps_by_key = true}, context.temp_allocator)
	if err != nil do return
	_record_drop(o, local_id)
	o.records[local_id] = _Record{type = strings.clone(type), name = strings.clone(name), text = strings.clone(string(text))}
}

@(private = "file")
_record_drop :: proc(o: ^_Owner, local_id: Local_ID) {
	if old, has := o.records[local_id]; has {
		delete(old.type, runtime.default_allocator())
		delete(old.name, runtime.default_allocator())
		delete(old.text, runtime.default_allocator())
		delete_key(&o.records, local_id)
	}
}

// --- A scene's records -------------------------------------------------------

// Adds a sub-asset to the scene: `type` and its data as JSON text.
// Returns the reference to it, to put in a field of the scene's objects.
scene_sub_asset_add :: proc(s: ^Scene, type: string, data_json: string, name := "") -> (ref: PPtr, ok: bool) {
	context.allocator = runtime.default_allocator()
	data, err := json.parse_string(data_json, .JSON, true)
	if err != nil do return {}, false
	a := Scene_Sub_Asset{local_id = scene_new_lid(s), type = strings.clone(type), name = strings.clone(name), data = data}
	append(&s.assets, a)
	_record_set(_owner(s.asset_guid), a.local_id, a.type, a.name, a.data)
	_scene_sub_assets_index_scene(s)
	return PPtr{guid = s.asset_guid, local_id = a.local_id}, true
}

// Replaces the data of the scene's sub-asset `local_id`. False when it
// has none under that id, or the text does not parse.
scene_sub_asset_set :: proc(s: ^Scene, local_id: Local_ID, data_json: string) -> bool {
	context.allocator = runtime.default_allocator()
	for &a in s.assets {
		if a.local_id != local_id do continue
		data, err := json.parse_string(data_json, .JSON, true)
		if err != nil do return false
		json.destroy_value(a.data)
		a.data = data
		_record_set(_owner(s.asset_guid), local_id, a.type, a.name, a.data)
		return true
	}
	return false
}

// Removes the scene's sub-asset `local_id`.
scene_sub_asset_remove :: proc(s: ^Scene, local_id: Local_ID) {
	context.allocator = runtime.default_allocator()
	for a, i in s.assets {
		if a.local_id != local_id do continue
		delete(a.type)
		delete(a.name)
		json.destroy_value(a.data)
		ordered_remove(&s.assets, i)
		_record_drop(_owner(s.asset_guid), local_id)
		_scene_sub_assets_index_scene(s)
		return
	}
}

// Whether the scene holds a sub-asset under `local_id`: sub-assets share the
// scene's local ids with its objects (scene_new_lid).
scene_sub_asset_has_local :: proc(s: ^Scene, local_id: Local_ID) -> bool {
	for a in s.assets do if a.local_id == local_id do return true
	return false
}

// Gives the scene's sub-asset `local_id` another name.
scene_sub_asset_rename :: proc(s: ^Scene, local_id: Local_ID, name: string) -> bool {
	context.allocator = runtime.default_allocator()
	for &a in s.assets {
		if a.local_id != local_id do continue
		delete(a.name)
		a.name = strings.clone(name)
		_record_set(_owner(s.asset_guid), local_id, a.type, a.name, a.data)
		_scene_sub_assets_index_scene(s)
		return true
	}
	return false
}

// The scene's sub-asset `local_id` as it is now: its type, name, data as
// JSON text and place in the list, on `allocator`. What an undo step keeps
// to put it back (scene_sub_asset_put). False for none.
scene_sub_asset_get :: proc(s: ^Scene, local_id: Local_ID, allocator := context.temp_allocator) -> (type, name, data_json: string, index: int, ok: bool) {
	for a, i in s.assets {
		if a.local_id != local_id do continue
		text, err := json.marshal(a.data, {spec = .JSON, sort_maps_by_key = true}, allocator)
		if err != nil do return
		return strings.clone(a.type, allocator), strings.clone(a.name, allocator), string(text), i, true
	}
	return
}

// Puts a sub-asset into the scene under a local id it had before: undo of a
// removal, redo of a creation. One already under that id is replaced. A new
// one goes to `index` of the list, so the file keeps its order.
scene_sub_asset_put :: proc(s: ^Scene, local_id: Local_ID, type, name, data_json: string, index: int) -> bool {
	context.allocator = runtime.default_allocator()
	data, err := json.parse_string(data_json, .JSON, true)
	if err != nil do return false
	for &a in s.assets {
		if a.local_id != local_id do continue
		delete(a.type)
		delete(a.name)
		json.destroy_value(a.data)
		a.type = strings.clone(type)
		a.name = strings.clone(name)
		a.data = data
		_record_set(_owner(s.asset_guid), local_id, a.type, a.name, a.data)
		_scene_sub_assets_index_scene(s)
		texture_unload(asset_key(PPtr{guid = s.asset_guid, local_id = local_id}))
		return true
	}
	a := Scene_Sub_Asset{local_id = local_id, type = strings.clone(type), name = strings.clone(name), data = data}
	inject_at(&s.assets, clamp(index, 0, len(s.assets)), a)
	_record_set(_owner(s.asset_guid), local_id, a.type, a.name, a.data)
	_scene_sub_assets_index_scene(s)
	return true
}

// The scene's records as the table has them: after a load, and after a save
// gave the scene its guid.
@(private)
_scene_sub_assets_publish :: proc(s: ^Scene) {
	o := _owner(s.asset_guid)
	// A scene's own records are the truth while it is open: its file is not
	// read over them.
	if !asset_guid_is_empty(s.asset_guid) {
		ids := make([dynamic]Local_ID, context.temp_allocator)
		for id in o.records do append(&ids, id)
		for id in ids do _record_drop(o, id)
		o.loaded = true
	}
	for a in s.assets do _record_set(o, a.local_id, a.type, a.name, a.data)
	_scene_sub_assets_index_scene(s)
}

// A scene going away: its records go, and the table forgets them. A scene
// file still read by others (nested somewhere) is read again on next use.
@(private)
_scene_sub_assets_destroy :: proc(s: ^Scene) {
	context.allocator = runtime.default_allocator()
	if asset_guid_is_empty(s.asset_guid) {
		o := _owner(s.asset_guid)
		for a in s.assets do _record_drop(o, a.local_id)
	} else {
		scene_sub_assets_drop(s.asset_guid)
		// Closed with edits it did not save: the database's list goes back
		// to what the file holds.
		if s.dirty && assets.asset_db.pipeline != .Catalog do _scene_sub_assets_index_records(s.asset_guid)
	}
	for a in s.assets {
		delete(a.type)
		delete(a.name)
		json.destroy_value(a.data)
	}
	delete(s.assets)
	s.assets = nil
}

// Forgets what the table read for the file `owner`: its bytes changed. They
// are read again on next use.
scene_sub_assets_drop :: proc(owner: Asset_GUID) {
	o, has := _owners[owner]
	if !has do return
	ids := make([dynamic]Local_ID, context.temp_allocator)
	for id in o.records do append(&ids, id)
	for id in ids do _record_drop(o, id)
	o.loaded = false
}

// --- Loading and saving ------------------------------------------------------

// Before a parsed scene file's components are read (_scene_load_as_child).
// `scope` is the file the content comes from when it is a nested prefab's,
// empty when it is the scene's own file. The scene's own load takes the
// file's records. References read until _scene_sub_assets_load_end are bound.
@(private)
_scene_sub_assets_load_begin :: proc(sf: ^SceneFile, s: ^Scene, scope: Asset_GUID) {
	own := asset_guid_is_empty(scope)
	if own && s != nil && len(sf.assets) > 0 {
		context.allocator = runtime.default_allocator()
		for a in sf.assets {
			for old, i in s.assets do if old.local_id == a.local_id {
				delete(old.type)
				delete(old.name)
				json.destroy_value(old.data)
				ordered_remove(&s.assets, i)
				break
			}
			append(&s.assets, Scene_Sub_Asset{local_id = a.local_id, type = strings.clone(a.type), name = strings.clone(a.name), data = json.clone_value(a.data)})
		}
		_scene_sub_assets_publish(s)
	}
	// A nested prefab's content: its own file first, then the bases it holds
	// content of when it is a variant, then the host, whose overrides may name
	// the host's records.
	_bind_owners_reset()
	if !own {
		g := scope
		for depth := 0; !asset_guid_is_empty(g) && depth <= 32; depth += 1 {
			append(&_bind_owners, g)
			g = _variant_bases[g]
		}
	}
	if s != nil do append(&_bind_owners, s.asset_guid)
	_binding = true
}

// A nested variant's flattened content holds the content of `base`.
@(private)
_scene_sub_assets_variant_base_set :: proc(variant, base: Asset_GUID) {
	context.allocator = runtime.default_allocator()
	_variant_bases[variant] = base
}

@(private = "file")
_bind_owners_reset :: proc() {
	if _bind_owners == nil do _bind_owners = make([dynamic]Asset_GUID, runtime.default_allocator())
	clear(&_bind_owners)
}

@(private)
_scene_sub_assets_load_end :: proc() {
	_binding = false
}

// Around the parse of an asset's data by its loader: when `key` names a
// scene sub-asset, references in its data that name records of the same file
// are bound to that file. Nothing to do for a whole asset.
asset_parse_begin :: proc(key: Asset_GUID) {
	ref, sub := asset_key_ref(key)
	if !sub do return
	_bind_owners_reset()
	append(&_bind_owners, ref.guid)
	_binding = true
}

asset_parse_end :: proc() {
	_binding = false
}

// Around the marshal of a scene sub-asset's data, before it is stored: its
// references to records of the same file are written with an empty guid, as
// the file holds them.
asset_write_begin :: proc(key: Asset_GUID) {
	ref, sub := asset_key_ref(key)
	if !sub || asset_guid_is_empty(ref.guid) do return
	_unbind_owner = ref.guid
	_unbinding = true
}

// The same around the marshal of data that goes into the file `owner` as a
// new sub-asset, which has no key yet. Ended by asset_write_end.
asset_write_begin_in :: proc(owner: Asset_GUID) {
	if asset_guid_is_empty(owner) do return
	_unbind_owner = owner
	_unbinding = true
}

asset_write_end :: proc() {
	_unbinding = false
}

// Around a scene's serialization: references into the scene's own file are
// written with an empty guid.
@(private)
_scene_sub_assets_save_begin :: proc(s: ^Scene) {
	_unbind_owner = s.asset_guid
	_unbinding = !asset_guid_is_empty(s.asset_guid)
}

@(private)
_scene_sub_assets_save_end :: proc() {
	_unbinding = false
}

// A reference read during a load: one with an empty guid that names a record
// of the file being loaded gets that file's guid.
@(private = "file")
_this_file_read_hook :: proc(p: ^PPtr) {
	if !_binding || p.local_id == 0 || !pptr_guid_is_empty(p.guid) do return
	for owner in _bind_owners {
		if asset_guid_is_empty(owner) do continue
		if scene_sub_asset_has(owner, p.local_id) {
			p.guid = owner
			return
		}
	}
}

// A reference written during a save: one that names a record of the scene
// being written loses its guid.
@(private = "file")
_this_file_write_hook :: proc(p: ^PPtr) {
	if !_unbinding || p.local_id == 0 || p.guid != _unbind_owner do return
	if scene_sub_asset_has(_unbind_owner, p.local_id) do p.guid = {}
}
