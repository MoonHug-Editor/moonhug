package serialization

// How a core.PPtr (a reference: an asset's guid and a local id inside it) is
// written and read.
//
//   - A reference to a whole asset (local id 0) is written as the asset's
//     guid, a string: the form a guid-only field has. So a field can change
//     from Asset_GUID to PPtr and its files stay as they are.
//   - Any other reference is written as `{"local_id": 1, "guid": "..."}` on
//     one line: a sub-asset, an object of the same file (empty guid), nothing
//     (both zero).
//   - Both forms are read, and null reads as nothing.
//
// A reference to something inside the file being read or written is saved
// with an empty guid, "this file", and holds the file's guid in memory. The
// engine installs the two hooks that turn one into the other, since only it
// knows which file that is (plugins/engine/scene_sub_assets.odin).

import "core:encoding/json"
import "core:encoding/uuid"
import "core:io"
import core "moonhug:libs/core"

// Called with every reference read, after it is parsed. nil does nothing.
pptr_read_hook: proc(p: ^core.PPtr)
// Called with a copy of every reference written, before it is written.
pptr_write_hook: proc(p: ^core.PPtr)

// An embedded asset: a reference whose asset is written in its place, as
// {"embedded": "<type>", "data": {...}}. The engine installs both.
// The type and data of the embedded asset `p` names, false for any other reference.
pptr_embedded_write: proc(p: core.PPtr) -> (type: string, data_json: string, ok: bool)
// The reference to an embedded asset of `type` with `data_json`: the one
// `id` names when it is not 0 and still there, else a new one.
pptr_embedded_read: proc(type: string, data_json: string, id: core.Local_ID) -> core.PPtr

// While set, an embedded asset is written with its id, `"id": 7`, and a read
// of that text gives the field the same embedded asset back. Undo sets it
// around the snapshots it takes, so a step put back does not make a new
// embedded asset and the asset's own edit steps still reach it. Nothing else
// writes the id: a file, a copy and a multi-edit each make an embedded asset
// of their own, so two fields never share one.
pptr_embedded_ids: bool

pptr_marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> json.Marshal_Error {
	p := (cast(^core.PPtr)v.data)^
	if pptr_embedded_write != nil {
		if type, data, embedded := pptr_embedded_write(p); embedded {
			io.write_string(w, `{"embedded": "`)
			io.write_string(w, type)
			if pptr_embedded_ids {
				io.write_string(w, `", "id": `)
				io.write_u64(w, u64(p.local_id))
				io.write_string(w, `, "data": `)
			} else {
				io.write_string(w, `", "data": `)
			}
			io.write_string(w, data)
			io.write_string(w, "}")
			return nil
		}
	}
	if pptr_write_hook != nil do pptr_write_hook(&p)
	if p.local_id == 0 && p.guid != {} do return asset_guid_marshal(w, any{&p.guid, typeid_of(core.Asset_GUID)}, opt)
	return struct_one_line_marshal(w, any{&p, typeid_of(core.PPtr)}, opt)
}

pptr_unmarshal :: proc(p: ^json.Parser, v: any) -> json.Unmarshal_Error {
	val, parse_err := json.parse_value(p)
	if parse_err != nil do return parse_err
	defer json.destroy_value(val)
	out: core.PPtr
	#partial switch x in val {
	case json.Null:
	case json.String:
		id, err := uuid.read(x)
		if err != nil do return json.Unmarshal_Data_Error.Invalid_Data
		out.guid = core.Asset_GUID(id)
	case json.Object:
		if type, embedded := x["embedded"].(json.String); embedded && pptr_embedded_read != nil {
			data, merr := json.marshal(x["data"], {spec = .JSON, sort_maps_by_key = true}, context.temp_allocator)
			if merr != nil do return json.Unmarshal_Data_Error.Invalid_Data
			id: core.Local_ID
			#partial switch n in x["id"] {
			case json.Integer: id = core.Local_ID(n)
			case json.Float:   id = core.Local_ID(n)
			}
			(cast(^core.PPtr)v.data)^ = pptr_embedded_read(string(type), string(data), id)
			return nil
		}
		if g, has := x["guid"].(json.String); has {
			id, err := uuid.read(g)
			if err != nil do return json.Unmarshal_Data_Error.Invalid_Data
			out.guid = core.Asset_GUID(id)
		}
		#partial switch n in x["local_id"] {
		case json.Integer: out.local_id = core.Local_ID(n)
		case json.Float:   out.local_id = core.Local_ID(n)
		}
	case:
		return json.Unmarshal_Data_Error.Invalid_Data
	}
	if pptr_read_hook != nil do pptr_read_hook(&out)
	(cast(^core.PPtr)v.data)^ = out
	return nil
}
