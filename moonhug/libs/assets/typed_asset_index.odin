package assets

// The type index of typed asset files: a JSON file whose `__type_guid` names
// a registered type (a .asset, a .renderpipeline) is listed under that type's
// key, with local id 0. asset_db_assets_with_root_type(key) returns it, so an
// Asset_GUID field tagged `ref:"Render_Pipeline"` offers only pipeline assets
// (docs/core/ObjectPicker.md).
//
// Every .asset file is indexed. A package whose type has its own extension
// registers the indexer for it: asset_db_add_indexer(".ext", asset_db_index_typed_asset).

import "base:runtime"
import "core:encoding/json"
import "core:encoding/uuid"
import core "moonhug:libs/core"

@(init)
_typed_asset_index_register :: proc "contextless" () {
	context = runtime.default_context()
	asset_db_add_indexer(".asset", asset_db_index_typed_asset)
}

// Indexes one typed asset file under its type. A file with no readable
// `__type_guid`, or one naming a type no installed plugin declares, is not
// indexed.
asset_db_index_typed_asset :: proc(guid: core.Asset_GUID, path: string, data: []byte) {
	Header :: struct {
		type_guid: string `json:"__type_guid"`,
	}
	h: Header
	if json.unmarshal(data, &h, allocator = context.temp_allocator) != nil do return
	id, id_err := uuid.read(h.type_guid)
	if id_err != nil do return
	tid, known := core.get_typeid_by_guid_ok(id)
	if !known do return
	key, keyed := core.get_type_key_by_typeid(tid)
	if !keyed do return
	context.allocator = runtime.default_allocator()
	_index_add(key, guid, 0)
}
