package engine

// Loading an asset before its first use. Every loader loads on first use
// (texture_load, mesh_load, clip_load): the first frame that draws or plays an
// asset pays for its file read, decode and GPU upload. A preload makes that
// happen at a chosen time: a scene load preloads every asset the scene
// references (scene_load_async.odin), and a game calls asset_preload for an
// asset it picks in code.
//
// An asset type joins with one attribute:
//
//   @(asset_preload={ext="mp3,wav,ogg"})
//   asset_preload_audio_clip :: proc(ref: engine.PPtr) { clip_load(ref.guid) }
//
// - The name is the contract: `asset_preload_<name>`, the name free.
// - `ext` lists the types the proc loads: file extensions without the dot,
//   or the type of a scene file's sub-asset ("mat", "noise").
// - Several procs can name one extension. Each gets the reference and loads
//   it only when it is its own: a model's file holds mesh parts and clips, the
//   mesh proc loads a part id and the animation proc loads a clip id.
// - The proc calls the type's loader, so a loaded asset costs a cache lookup.
// - A reference to a sub-asset of a scene file is a PPtr, and a loader that
//   takes one guid gets `asset_key(ref)`.

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:path/filepath"
import "core:strings"
import core "moonhug:libs/core"

Asset_Preload :: proc(ref: PPtr)

@(private = "file")
_Preload_Entry :: struct {
	type: string, // "png", lower case, no dot
	load: Asset_Preload,
}

@(private = "file")
_preloads: [dynamic]_Preload_Entry

// Declares `asset_preload_<name>`, which loads one asset before its first
// use. `ext` lists the asset types it loads, separated by commas: file
// extensions without the dot, or scene sub-asset types.
// Registry state never borrows the caller's allocator.
@(extension_point={attribute="asset_preload", target="proc", fields="ext"})
asset_preload_add :: proc(ext: string, load: Asset_Preload) {
	context.allocator = runtime.default_allocator()
	rest := ext
	for part in strings.split_iterator(&rest, ",") {
		type := strings.trim_space(part)
		if len(type) > 0 && type[0] == '.' do type = type[1:]
		if type == "" do continue
		type = strings.to_lower(type, context.temp_allocator)
		known := false
		for e in _preloads do if e.type == type && e.load == load do known = true
		if !known do append(&_preloads, _Preload_Entry{type = strings.clone(type), load = load})
	}
}

// Loads the asset `ref` names now, so its first use does not. False when no
// preload proc knows the asset's type: the asset then loads on first use.
asset_preload :: proc(ref: PPtr) -> bool {
	type := asset_ref_type(ref)
	if type == "" do return false
	found := false
	for e in _preloads {
		if e.type != type do continue
		e.load(ref)
		found = true
	}
	return found
}

// The type of the asset `ref` names, lower case without a dot: the type of a
// scene file's sub-asset, else the extension of the file. "" for an unknown
// guid, and for an object of a scene.
asset_ref_type :: proc(ref: PPtr) -> string {
	path, ok := asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return ""
	ext := filepath.ext(path)
	if len(ext) > 0 do ext = ext[1:]
	ext = strings.to_lower(ext, context.temp_allocator)
	if ext == "scene" && ref.local_id != 0 do return scene_sub_asset_type(ref)
	return ext
}

// --- The engine's asset types ---------------------------------------------------

@(asset_preload={ext="png,jpg,jpeg,bmp,hdr,noise"})
asset_preload_texture :: proc(ref: PPtr) {
	// A sprite is {texture, sprite id}: the texture holds every sprite.
	// A noise map can be a sub-asset of a scene file, loaded by its key.
	texture_load(asset_key(ref) if asset_ref_type(ref) == "noise" else ref.guid)
}

@(asset_preload={ext="glb,gltf"})
asset_preload_mesh :: proc(ref: PPtr) {
	if ref.local_id == 0 {
		mesh_load(ref.guid)
		return
	}
	for part in mesh_parts(ref.guid) {
		if part.id != ref.local_id do continue
		mesh_load(ref.guid, i32(ref.local_id))
		return
	}
}

// The material, its shader and its textures.
@(asset_preload={ext="mat"})
asset_preload_material :: proc(ref: PPtr) {
	_resolve_material(asset_key(ref))
}

@(asset_preload={ext="glsl,shadergraph"})
asset_preload_shader :: proc(ref: PPtr) {
	shader_load(ref.guid)
}

// --- The references of a scene file --------------------------------------------

// What scene_file_asset_refs found in one scene file.
Scene_Asset_Refs :: struct {
	assets: [dynamic]PPtr, // every asset that is not a scene, once each
	scenes: [dynamic]Asset_GUID, // the nested prefabs, once each
}

// Adds every asset reference in the scene file `sf` to `out`, skipping what
// `out` already lists. `owner` is the file's guid: a reference with the empty
// guid names a sub-asset of this file. A reference is a guid string, or
// {local_id, guid}. The walk reads the components, the sub-asset records and
// the override records of nested prefabs. It does not open the nested
// prefabs: they are in `out.scenes` for the caller to walk.
//
// A scene a field names is not listed: a list of levels would load every
// level's assets. A script that spawns a prefab from a field calls
// asset_preload on it.
scene_file_asset_refs :: proc(sf: ^SceneFile, owner: Asset_GUID, out: ^Scene_Asset_Refs) {
	for c in sf.components do _refs_walk(c, owner, out)
	for a in sf.assets do _refs_walk(a.data, owner, out)
	for &ns in sf.nested_scenes {
		if !asset_guid_is_empty(ns.source_prefab) {
			known := false
			for g in out.scenes do if g == ns.source_prefab do known = true
			if !known do append(&out.scenes, ns.source_prefab)
		}
		for ov in ns.overrides do _refs_walk(ov.value, owner, out)
		for ac in ns.added_components do _refs_walk_text(ac.json, owner, out)
		for ao in ns.added_objects do _refs_walk_text(ao.json, owner, out)
	}
}

@(private = "file")
_refs_walk_text :: proc(text: string, owner: Asset_GUID, out: ^Scene_Asset_Refs) {
	if text == "" do return
	v, err := json.parse_string(text, parse_integers = true, allocator = context.temp_allocator)
	if err != nil do return
	_refs_walk(v, owner, out)
}

@(private = "file")
_refs_walk :: proc(v: json.Value, owner: Asset_GUID, out: ^Scene_Asset_Refs) {
	#partial switch x in v {
	case json.Object:
		// {local_id, guid}: one reference, to a sub-asset.
		if gs, has := x["guid"].(json.String); has && "local_id" in x {
			if guid, ok := _refs_guid(gs); ok {
				_refs_add(PPtr{guid = guid, local_id = _refs_int(x["local_id"])}, owner, out)
				return
			}
		}
		for k, child in x {
			if k == "__type" || k == "__type_guid" do continue
			_refs_walk(child, owner, out)
		}
	case json.Array:
		for child in x do _refs_walk(child, owner, out)
	case json.String:
		if guid, ok := _refs_guid(x); ok do _refs_add(PPtr{guid = guid}, owner, out)
	}
}

// A guid string, the zero guid included ("this file").
@(private = "file")
_refs_guid :: proc(s: string) -> (Asset_GUID, bool) {
	if len(s) != 36 do return {}, false
	id, err := uuid.read(s)
	if err != nil do return {}, false
	return Asset_GUID(id), true
}

@(private = "file")
_refs_int :: proc(v: json.Value) -> Local_ID {
	#partial switch x in v {
	case json.Integer: return Local_ID(x)
	case json.Float:   return Local_ID(x)
	}
	return 0
}

@(private = "file")
_refs_add :: proc(ref: PPtr, owner: Asset_GUID, out: ^Scene_Asset_Refs) {
	ref := ref
	if asset_guid_is_empty(ref.guid) {
		// The empty guid with a local id: a sub-asset of this file, or one
		// of its objects. Only the first is an asset.
		if ref.local_id == 0 || asset_guid_is_empty(owner) do return
		ref.guid = owner
		if scene_sub_asset_type(ref) == "" do return
	} else {
		if _, is_type := core.get_typeid_by_guid_ok(uuid.Identifier(ref.guid)); is_type do return
	}
	type := asset_ref_type(ref)
	if type == "" || type == "scene" do return
	for r in out.assets do if r == ref do return
	append(&out.assets, ref)
}
