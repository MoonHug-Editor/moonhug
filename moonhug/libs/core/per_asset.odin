package core

// Per-asset user settings: what a developer keeps for each asset, such as the
// rows of a scene left open in the Hierarchy or where the Scene window looked
// at it. A @(user_settings) var of type Per_Asset(T) is saved with the other
// user settings, in UserSettings/<name>.json, never committed: an entry per
// asset, by the asset's guid.
//
//   @(user_settings={name="Scene Cameras"})
//   scene_cameras: core.Per_Asset(Scene_Camera)
//
// An entry lives while its asset does. The editor drops an asset's entries
// from every Per_Asset when the asset leaves the project, and those of assets
// gone while it was closed when it saves them (per_asset_prune).
//
// T is a plain value, or a dynamic array of plain values: dropping an entry
// frees the array and nothing deeper.

@(require) import "base:intrinsics"
// Used inside the generic procs only, which a build without users never instantiates.
@(require) import "base:runtime"
import "core:encoding/uuid"

Per_Asset :: struct($T: typeid) {
	entries: map[string]T, // by the asset's guid, as text
}

// The entry of `guid`, nil when it has none.
per_asset_get :: proc(p: ^Per_Asset($T), guid: Asset_GUID) -> ^T {
	if guid == {} do return nil
	if v, ok := &p.entries[_per_asset_key(guid)]; ok do return v
	return nil
}

// The entry of `guid`, made zero when it has none. Nil for no asset.
per_asset_entry :: proc(p: ^Per_Asset($T), guid: Asset_GUID) -> ^T {
	if guid == {} do return nil
	key := _per_asset_key(guid)
	if v, ok := &p.entries[key]; ok do return v
	context.allocator = runtime.default_allocator()
	p.entries[uuid.to_string(uuid.Identifier(guid))] = {}
	return &p.entries[key]
}

// Drops the entry of `guid`, if there is one.
per_asset_drop :: proc(p: ^Per_Asset($T), guid: Asset_GUID) {
	_per_asset_drop_key(p, _per_asset_key(guid))
}

// Makes `p` one the editor keeps tidy (per_asset_drop_all, per_asset_prune).
// user_settings_load calls it for every Per_Asset var.
per_asset_register :: proc(p: ^Per_Asset($T)) {
	for r in _per_asset_registry do if r.data == p do return
	context.allocator = runtime.default_allocator()
	append(&_per_asset_registry, _Per_Asset_Registered{
		data = p,
		drop = proc(data: rawptr, key: string) {
			_per_asset_drop_key((^Per_Asset(T))(data), key)
		},
		keys = proc(data: rawptr, out: ^[dynamic]string) {
			for k in (^Per_Asset(T))(data).entries do append(out, k)
		},
	})
}

// Drops the entries of `guid` from every registered Per_Asset: the asset left
// the project.
per_asset_drop_all :: proc(guid: Asset_GUID) {
	key := _per_asset_key(guid)
	for r in _per_asset_registry do r.drop(r.data, key)
}

// Drops the entries of every asset `known` says is gone, from every
// registered Per_Asset. The editor runs it before it saves the user
// settings, while the asset database still knows the project.
per_asset_prune :: proc(known: proc(guid: Asset_GUID) -> bool) {
	for r in _per_asset_registry {
		keys := make([dynamic]string, context.temp_allocator)
		r.keys(r.data, &keys)
		for k in keys {
			id, err := uuid.read(k)
			if err != nil || !known(Asset_GUID(id)) do r.drop(r.data, k)
		}
	}
}

@(private = "file")
_Per_Asset_Registered :: struct {
	data: rawptr,
	drop: proc(data: rawptr, key: string),
	keys: proc(data: rawptr, out: ^[dynamic]string),
}

// Every Per_Asset loaded, on the default allocator.
@(private = "file")
_per_asset_registry: [dynamic]_Per_Asset_Registered

@(private = "file")
_per_asset_key :: proc(guid: Asset_GUID) -> string {
	return uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
}

@(private = "file")
_per_asset_drop_key :: proc(p: ^Per_Asset($T), key: string) {
	if key not_in p.entries do return
	k, v := delete_key(&p.entries, key)
	context.allocator = runtime.default_allocator()
	delete(k)
	when intrinsics.type_is_dynamic_array(T) {
		delete(v)
	} else {
		_ = v // a plain value owns nothing
	}
}
