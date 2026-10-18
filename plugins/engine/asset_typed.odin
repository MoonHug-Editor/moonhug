package engine

// Reading a plain .asset file as one known type, for code that owns an asset
// type and reads it outside the asset documents: layer names, a collision
// matrix. A field the file lacks keeps its reset default (Components.md
// "Missing fields and reset defaults"). A file of another type does not load.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"

// Parses `data` as a T asset. ok=false when the file names another type or
// does not parse, with nothing left allocated.
asset_parse_as :: proc(data: []u8, $T: typeid) -> (v: T, ok: bool) {
	Header :: struct {
		type_guid: string `json:"__type_guid"`,
	}
	h: Header
	if json.unmarshal(data, &h, allocator = context.temp_allocator) != nil do return {}, false
	id, id_err := uuid.read(h.type_guid)
	if id_err != nil || id != get_guid_by_typeid(T) do return {}, false
	if unmarshal_over_reset(data, &v, typeid_of(T)) != nil {
		type_cleanup_by_typeid(typeid_of(T), &v)
		return {}, false
	}
	return v, true
}

// Reads the asset `guid` names as a T. ok=false when the asset is missing,
// unreadable or of another type.
asset_load_as :: proc(guid: Asset_GUID, $T: typeid) -> (v: T, ok: bool) {
	path, has := asset_db_get_path(uuid.Identifier(guid))
	if !has do return {}, false
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return asset_parse_as(data, T)
}
