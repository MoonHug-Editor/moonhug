package engine

// The asset references in a scene file that do not resolve. A scene names
// assets by guid (meshes, materials, clips, nested scenes), and the loaders
// resolve each one lazily when it is first drawn or played. A guid the asset
// database does not know draws or plays nothing, silently. The standalone
// player checks every scene it loads from a file and logs each such
// reference, so a scene whose assets were not exported explains itself in the
// Console instead of showing an empty view.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:libs/log"

Missing_Asset_Ref :: struct {
	guid:      string, // the guid as written
	object:    string, // the name of the object whose component holds it, "" outside a component
	component: string, // the component's type, "" outside a component
	field:     string, // the field it sits under: "materials", "source_prefab"
}

// Whether `guid` names an asset or a sub-asset (a model's clip) the asset
// database knows.
scene_asset_resolves :: proc(guid: uuid.Identifier) -> bool {
	if _, ok := assets.asset_db_get_path(guid); ok do return true
	_, ok := assets.asset_db_get_sub(core.Asset_GUID(guid))
	return ok
}

// Every guid in the scene file `data` that is not a type guid and does not
// resolve. Type guids sit under `__type` and `__type_guid`, and the zero guid
// is a reference to nothing. Temp-allocated.
scene_missing_assets :: proc(data: []byte, resolves: proc(guid: uuid.Identifier) -> bool = scene_asset_resolves) -> []Missing_Asset_Ref {
	context.allocator = context.temp_allocator
	root, err := json.parse(data, parse_integers = true)
	if err != nil do return nil
	obj, is_obj := root.(json.Object)
	if !is_obj do return nil

	// Component local id -> the name of the object listing it.
	owners := make(map[i64]string)
	if transforms, ok := obj["transforms"].(json.Array); ok {
		for tv in transforms {
			t := tv.(json.Object) or_continue
			name, _ := t["name"].(json.String)
			comps := t["components"].(json.Array) or_continue
			for cv in comps {
				c := cv.(json.Object) or_continue
				if id, has := c["local_id"].(json.Integer); has do owners[id] = name
			}
		}
	}

	out := make([dynamic]Missing_Asset_Ref)
	for key, value in obj {
		if key != "components" {
			_missing_walk(value, key, "", "", resolves, &out)
			continue
		}
		comps := value.(json.Array) or_continue
		for cv in comps {
			c := cv.(json.Object) or_continue
			type_name := "component"
			if g, has := c["__type"].(json.String); has {
				if id, perr := uuid.read(g); perr == nil {
					if T, known := core.get_typeid_by_guid_ok(id); known do type_name = fmt.tprint(T)
				}
			}
			object := ""
			if base, has := c["base"].(json.Object); has {
				if id, hid := base["local_id"].(json.Integer); hid do object = owners[id]
			}
			for field, fv in c do _missing_walk(fv, field, object, type_name, resolves, &out)
		}
	}
	return out[:]
}

@(private = "file")
_missing_walk :: proc(v: json.Value, field, object, component: string, resolves: proc(guid: uuid.Identifier) -> bool, out: ^[dynamic]Missing_Asset_Ref) {
	switch x in v {
	case json.Object:
		for k, child in x {
			if k == "__type" || k == "__type_guid" do continue
			// A reference written as {pptr: {local_id, guid}} keeps the field
			// it belongs to, not "pptr" or "guid".
			next := field if k == "pptr" || k == "guid" else k
			_missing_walk(child, next, object, component, resolves, out)
		}
	case json.Array:
		for child in x do _missing_walk(child, field, object, component, resolves, out)
	case json.String:
		if len(x) != 36 do return
		id, perr := uuid.read(x)
		if perr != nil || id == {} do return
		if _, is_type := core.get_typeid_by_guid_ok(id); is_type do return
		if resolves(id) do return
		ref := Missing_Asset_Ref{guid = x, object = object, component = component, field = field}
		// One entry per holder, however often the field repeats the guid.
		for m in out do if m == ref do return
		append(out, ref)
	case json.Null, json.Integer, json.Float, json.Boolean:
	}
}

// Logs every reference in the scene file at `path` that names an asset the
// asset database does not have, one error each.
scene_log_missing_assets :: proc(path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	for m in scene_missing_assets(data) {
		where_ := fmt.tprintf("%s.%s", m.component, m.field) if m.component != "" else m.field
		if m.object != "" do where_ = fmt.tprintf("%s, %s", m.object, where_)
		log.errorf("[Scene] %s: %s references asset %s, which is not in the asset catalog", path, where_, m.guid)
	}
}
