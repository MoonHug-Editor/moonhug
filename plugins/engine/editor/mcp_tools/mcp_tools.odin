package mcp_tools

// The engine's MCP tools: the ones that read or edit the world (scenes,
// objects, components). The bridge in the shell (editor/mcp_bridge.odin)
// dispatches to them through the table mcp_tool_gen writes.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import mcp "moonhug:editor/mcp"
import "moonhug:editor/inspector"
import sim "moonhug:editor/simulate"
import "moonhug:editor/session"
import "moonhug:packages/engine"

Mcp_Error :: mcp.Tool_Error

// --- Read tools ------------------------------------------------------------------

@(private = "file")
_mcp_selection_names :: proc() -> []string {
	w := engine.ctx_world()
	names := make([dynamic]string, context.temp_allocator)
	for tH in session.selection() {
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			append(&names, t.name)
		}
	}
	return names[:]
}

@(mcp_tool={description="Editor status: active scene, simulate state, selection. Call first to orient."})
mcp_tool_editor_state :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	scene_path: string
	if s := engine.sm_scene_get_active(); s != nil do scene_path = s.path

	// local_ids alongside names because names repeat — the ids are what select
	// and set_transform address, and what makes a multi-selection reproducible.
	w := engine.ctx_world()
	ids := make([dynamic]engine.Local_ID, 0, len(session.selection()), context.temp_allocator)
	for tH in session.selection() {
		if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
			append(&ids, t.local_id)
		}
	}

	return mcp.tool_ok(struct {
		scene:              string,
		simulate:           string,
		selection:          []string,
		selection_local_ids: []engine.Local_ID,
	}{
		scene              = scene_path,
		simulate           = fmt.tprintf("%v", sim.state()),
		selection          = _mcp_selection_names(),
		selection_local_ids = ids[:],
	})
}

@(mcp_tool={
	description="Active scene contents: a summary (roots, transform count, selection) or the full serialized scene. A full dump is the whole file and can be very large — it is refused above max_bytes, and list_objects plus get_property answer most questions for a fraction of it.",
	param_full="boolean:Return the complete serialized scene JSON instead of the summary",
	param_max_bytes="integer:Refuse a full dump larger than this (default 8000)",
})
mcp_tool_scene_dump :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return mcp.tool_fail("no_scene", "no active scene")

	full, _ := params["full"].(json.Boolean)
	if full {
		data, ok := engine.scene_serialize(s)
		if !ok do return mcp.tool_fail("serialize_failed", "scene_serialize failed")
		defer delete(data)
		// 8000 bytes is roughly 2000 tokens. Half the sample scenes fit under
		// it; the ones that do not are exactly the ones worth refusing, since
		// a 32 KB dump costs more context than every other call in a session
		// put together and almost always answers a question list_objects and
		// get_property would have answered for a fraction.
		max_bytes := int(mcp.json_int(params, "max_bytes", 8000))
		if max_bytes > 0 && len(data) > max_bytes {
			return mcp.tool_fail("too_large",
				"the full scene is %d bytes, over max_bytes %d — raise max_bytes deliberately, or use list_objects and get_property",
				len(data), max_bytes)
		}
		return mcp.tool_ok(struct {
			path:  string,
			scene: string,
		}{path = s.path, scene = string(data)})
	}

	w := engine.ctx_world()
	roots := make([dynamic]string, context.temp_allocator)
	count := 0
	it := engine.pool_iterator(&w.transforms)
	for t, _ in engine.pool_next(&it) {
		if t.scene != s do continue
		count += 1
		if t.parent.handle == s.root.handle do append(&roots, t.name)
	}
	return mcp.tool_ok(struct {
		path:            string,
		transform_count: int,
		roots:           []string,
		selection:       []string,
	}{path = s.path, transform_count = count, roots = roots[:], selection = _mcp_selection_names()})
}

// What a component IS, from the live registry and Odin reflection — the
// question an agent otherwise answers by guessing a field name and reading the
// error. The registry is the same one the inspector draws from, so a plugin's
// components appear here and a disabled plugin's do not.
//
// Type-level, so it needs no object: `path` walks field names, skipping array
// indices (`layers[0].states` and `layers.states` describe the same type),
// which means the path that addresses a value in get_property also describes
// its shape here.
@(private = "file")
_describe_find_type :: proc(name: string) -> (typeid, engine.TypeKey, bool) {
	for desc, key in engine.component_registry {
		if desc.tid == nil do continue
		if fmt.tprintf("%v", desc.tid) == name || fmt.tprintf("%v", key) == name {
			return desc.tid, key, true
		}
	}
	return nil, {}, false
}

// Unwraps arrays and pointers to the type a path segment can name fields on.
@(private = "file")
_describe_elem :: proc(tid: typeid) -> typeid {
	cur := tid
	for {
		ti := runtime.type_info_base(type_info_of(cur))
		#partial switch v in ti.variant {
		case runtime.Type_Info_Array:         cur = v.elem.id
		case runtime.Type_Info_Dynamic_Array: cur = v.elem.id
		case runtime.Type_Info_Slice:         cur = v.elem.id
		case runtime.Type_Info_Pointer:
			if v.elem == nil do return cur
			cur = v.elem.id
		case:
			return cur
		}
	}
}

// Fields of `tid` as JSON, omitting what a field does not declare — a listing
// of empty tag strings would be most of the payload.
@(private = "file")
_describe_fields_json :: proc(tid: typeid) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	ti := runtime.type_info_base(type_info_of(tid))
	if _, is_struct := ti.variant.(runtime.Type_Info_Struct); !is_struct {
		strings.write_string(&b, "]")
		return strings.to_string(b)
	}
	n := 0
	for f in reflect.struct_fields_zipped(tid) {
		if n > 0 do strings.write_string(&b, ",")
		n += 1
		name, _ := json.marshal(f.name, {}, context.temp_allocator)
		ftype, _ := json.marshal(fmt.tprintf("%v", f.type.id), {}, context.temp_allocator)
		fmt.sbprintf(&b, `{{"name":%s,"type":%s`, string(name), string(ftype))
		for tag in ([?]string{"ref", "has", "pick", "ext"}) {
			v, has := reflect.struct_tag_lookup(f.tag, tag)
			if !has || v == "" do continue
			tv, _ := json.marshal(v, {}, context.temp_allocator)
			fmt.sbprintf(&b, `,"%s":%s`, tag, string(tv))
		}
		// A field the serializer skips can be written, but the write does not
		// survive a save — worth knowing before setting one.
		if j, has_j := reflect.struct_tag_lookup(f.tag, "json"); has_j && j == "-" {
			strings.write_string(&b, `,"serialized":false`)
		}
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

@(mcp_tool={
	description="What a component looks like: its fields, their types, and the ref:/has: tags that say what a reference field accepts. Omit type to list every registered component. Type-level, so it needs no object — check a field exists and what it admits BEFORE calling set_property, instead of learning it from the error. path walks into a field and describes that type, ignoring array indices, so the same path that addresses a value in get_property describes its shape here.",
	param_type="string:Component type name as list_objects prints it; omit to list every registered component",
	param_path="string:Field path into the type, e.g. layers or layers[0].states",
})
mcp_tool_describe_type :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	name, has_name := params["type"].(json.String)
	if !has_name || name == "" {
		names := make([dynamic]string, context.temp_allocator)
		for desc in engine.component_registry {
			if desc.tid == nil do continue
			append(&names, fmt.tprintf("%v", desc.tid))
		}
		slice.sort(names[:])
		return mcp.tool_ok(struct {
			components: []string,
		}{components = names[:]})
	}

	tid, key, found := _describe_find_type(string(name))
	if !found do return mcp.tool_fail("not_found", "no registered component named %q — call describe_type with no type to list them", name)

	cur := tid
	path, _ := params["path"].(json.String)
	if path != "" {
		for seg in strings.split(string(path), ".", context.temp_allocator) {
			field := seg
			if open := strings.index_byte(field, '['); open >= 0 do field = field[:open]
			if field == "" do return mcp.tool_fail("bad_path", "%s: empty segment", path)
			owner := _describe_elem(cur)
			f := reflect.struct_field_by_name(owner, field)
			if f.name == "" {
				return mcp.tool_fail("bad_path", "%v has no field %q", owner, field)
			}
			cur = f.type.id
		}
	}

	elem := _describe_elem(cur)
	ref_tags := engine.component_registry[key].ref_tags
	if ref_tags == nil do ref_tags = {}
	return fmt.tprintf(
		`{{"type":%q,"element":%q,"ref_tags":%s,"fields":%s}}`,
		fmt.tprintf("%v", cur), fmt.tprintf("%v", elem),
		_mcp_strings_json(ref_tags), _describe_fields_json(elem)), {}
}

@(private = "file")
_mcp_strings_json :: proc(xs: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	for x, i in xs {
		if i > 0 do strings.write_string(&b, ",")
		v, _ := json.marshal(x, {}, context.temp_allocator)
		strings.write_string(&b, string(v))
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

@(mcp_tool={
	description="Objects in the active scene: local_id, name, parent and the components each carries — enough to pick what to read with get_property. Filter by name and/or component, which is how you answer \"every object with an X\" without listing the scene. PAGINATED: 50 per page by default, next_cursor is -1 on the last page. World positions are opt-in, since they are the bulk of the payload. Names repeat, so address an object by local_id.",
	param_name="string:Only objects whose name contains this text",
	param_component="string:Only objects carrying this component, named as this tool prints it (see describe_type)",
	param_page_size="integer:Objects per page (default 50, max 500)",
	param_cursor="integer:Index to resume from — next_cursor from the previous page",
	param_detail="boolean:Also return each object's world position",
})
mcp_tool_list_objects :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return mcp.tool_fail("no_scene", "no active scene")
	filter, _ := params["name"].(json.String)
	comp_filter, _ := params["component"].(json.String)
	// A component name that matches nothing is a typo, not an empty scene —
	// an empty list would read as "no such objects" and send the caller
	// looking in the wrong place.
	if comp_filter != "" {
		if _, _, known := _describe_find_type(string(comp_filter)); !known {
			return mcp.tool_fail("not_found",
				"no registered component named %q — call describe_type with no type to list them", comp_filter)
		}
	}

	// `position` is a slice so it can be absent: a scene's worth of full-
	// precision floats is most of the payload, and a listing is usually asked
	// to find an object, not to measure one.
	Obj :: struct {
		local_id:   u64,
		name:       string,
		parent:     string,
		components: []string,
		position:   []f32,
	}
	page_size := int(mcp.json_int(params, "page_size", 50))
	if page_size <= 0 do page_size = 50
	if page_size > 500 do page_size = 500
	cursor := int(mcp.json_int(params, "cursor", 0))
	if cursor < 0 do cursor = 0
	detail, _ := params["detail"].(json.Boolean)

	w := engine.ctx_world()
	out := make([dynamic]Obj, context.temp_allocator)
	total := 0
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s do continue
		if filter != "" && !strings.contains(t.name, filter) do continue

		// Component names are needed for the filter and for the reply, so they
		// are collected once, before the paging cut.
		comps := make([dynamic]string, context.temp_allocator)
		for c in t.components {
			if tid := engine.get_typeid_by_type_key(c.handle.type_key); tid != nil {
				append(&comps, fmt.tprintf("%v", tid))
			}
		}
		if comp_filter != "" {
			carries := false
			for cn in comps do if cn == string(comp_filter) { carries = true; break }
			if !carries do continue
		}
		total += 1
		index := total - 1
		if index < cursor || len(out) >= page_size do continue

		parent_name: string
		if pt := engine.pool_get(&w.transforms, t.parent.handle); pt != nil do parent_name = pt.name
		h := h
		h.type_key = .Transform
		obj := Obj{
			local_id   = u64(t.local_id),
			name       = t.name,
			parent     = parent_name,
			components = comps[:],
		}
		if detail {
			p := engine.transform_world(engine.Transform_Handle(h)).position
			pos := make([]f32, 3, context.temp_allocator)
			pos[0], pos[1], pos[2] = p.x, p.y, p.z
			obj.position = pos
		}
		append(&out, obj)
	}

	next := cursor + len(out)
	if next >= total do next = -1
	return mcp.tool_ok(struct {
		objects:     []Obj,
		total:       int,
		next_cursor: int,
	}{objects = out[:], total = total, next_cursor = next})
}

// --- Write tools -----------------------------------------------------------------
// Every mutation runs through the editor's own undo stack, so an agent edit is
// Ctrl+Z-able and indistinguishable from a manual one.

// Resolves an object by local_id (from list_objects), else by exact name.
@(private = "file")
// Matches prefab-instance contents too — everything list_objects prints. Every
// bridge write goes through inspector.property_set_json, which records the
// override the inspector would, so instance content is as writable here as
// in the inspector.
_mcp_find_object :: proc(params: json.Object) -> (engine.Transform_Handle, Mcp_Error) {
	s := engine.sm_scene_get_active()
	if s == nil do return {}, Mcp_Error{"no_scene", "no active scene"}

	if lid := mcp.json_int(params, "local_id", 0); lid != 0 {
		if tH, ok := engine.scene_find_selectable_transform_local_id(s, engine.Local_ID(lid)); ok {
			return tH, {}
		}
		return {}, Mcp_Error{"not_found", fmt.tprintf("no object with local_id %d — see list_objects", lid)}
	}

	name, has := params["name"].(json.String)
	if !has do return {}, Mcp_Error{"bad_request", "need local_id or name"}
	w := engine.ctx_world()
	found: engine.Transform_Handle
	matches := 0
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.name != name do continue
		matches += 1
		h := h
		h.type_key = .Transform
		found = engine.Transform_Handle(h)
	}
	if matches == 0 do return {}, Mcp_Error{"not_found", fmt.tprintf("no object named %q — see list_objects", name)}
	if matches > 1 {
		return {}, Mcp_Error{"ambiguous", fmt.tprintf("%d objects named %q — use local_id from list_objects", matches, name)}
	}
	return found, {}
}

@(mcp_tool={
	description="Select objects in the scene. Pass local_ids for an exact set (multi-selection, which is what the inspector multi-edits), or name to select every object with that name. Empty call clears the selection.",
	param_local_ids="integer[]:Object local_ids from list_objects; selects exactly these, in order (last = active)",
	param_name="string:Object name to select; selects ALL objects with this name",
	param_add="boolean:Add to the current selection instead of replacing it",
})
mcp_tool_select :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	add, _ := params["add"].(json.Boolean)

	// An explicit id list is the precise form: it can build any selection,
	// including several objects that share a name.
	if raw_ids, has_ids := params["local_ids"].(json.Array); has_ids {
		s := engine.sm_scene_get_active()
		if s == nil do return mcp.tool_fail("no_scene", "no active scene")
		if !add do session.select_clear()

		missing := make([dynamic]i64, 0, len(raw_ids), context.temp_allocator)
		count := 0
		for entry in raw_ids {
			f, is_num := entry.(json.Float)
			if !is_num do return mcp.tool_fail("bad_param", "local_ids must contain numbers")
			lid := engine.Local_ID(i64(f))
			tH, found := engine.scene_find_selectable_transform_local_id(s, lid)
			if !found {
				append(&missing, i64(f))
				continue
			}
			session.select_add(tH)
			count += 1
		}
		if len(missing) > 0 {
			return mcp.tool_fail("not_found", "local_ids not in the active scene: %v — see list_objects", missing[:])
		}
		return mcp.tool_ok(struct{ selected: int }{count})
	}

	name, has := params["name"].(json.String)
	if !has || name == "" {
		session.select_clear()
		return mcp.tool_ok(struct{ selected: int }{0})
	}
	s := engine.sm_scene_get_active()
	if s == nil do return mcp.tool_fail("no_scene", "no active scene")
	w := engine.ctx_world()
	if !add do session.select_clear()
	count := 0
	it := engine.pool_iterator(&w.transforms)
	for t, h in engine.pool_next(&it) {
		if t.scene != s || t.name != name do continue
		h := h
		h.type_key = .Transform
		session.select_add(engine.Transform_Handle(h))
		count += 1
	}
	if count == 0 do return mcp.tool_fail("not_found", "no object named %q — see list_objects", name)
	return mcp.tool_ok(struct{ selected: int }{count})
}

@(mcp_tool={
	description="Set a transform field on one object. Address it by local_id (preferred) or exact name. One undo step.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact object name (alternative to local_id)",
	param_field="string!:position, rotation (euler degrees) or scale",
	param_x="number:X component",
	param_y="number:Y component",
	param_z="number:Z component",
})
mcp_tool_set_transform :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	tH, ferr := _mcp_find_object(params)
	if ferr.code != "" do return "", ferr
	field, has := params["field"].(json.String)
	if !has do return mcp.tool_fail("bad_request", "need field (position, rotation or scale)")

	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return mcp.tool_fail("not_found", "object went away")

	// Missing components keep their current value (partial edits).
	current: [3]f32
	switch field {
	case "position": current = t.position
	case "scale":    current = t.scale
	case "rotation": current = engine.quat_to_euler_xyz(t.rotation)
	case:
		return mcp.tool_fail("bad_request", "field must be position, rotation or scale")
	}
	v := current
	if f, ok := mcp.json_f32(params, "x"); ok do v.x = f
	if f, ok := mcp.json_f32(params, "y"); ok do v.y = f
	if f, ok := mcp.json_f32(params, "z"); ok do v.z = f

	// Through the property path: one undo step, and on prefab-instance content
	// the override the inspector's transform rows would record. The euler
	// conversion is this tool's own convenience — the field stores a quaternion.
	p, pok := inspector.inspect_transform(tH)
	if !pok do return mcp.tool_fail("not_found", "object went away")
	fp, _ := inspector.property(p, field)
	encoded: []byte
	merr: json.Marshal_Error
	if field == "rotation" {
		encoded, merr = json.marshal(engine.quat_from_euler_xyz(v.x, v.y, v.z), {}, context.temp_allocator)
	} else {
		encoded, merr = json.marshal(v, {}, context.temp_allocator)
	}
	if merr != nil do return mcp.tool_fail("bad_value", "could not encode %s", field)
	if ok, why := inspector.property_set_json(fp, encoded, fmt.tprintf("Set %s (MCP)", strings.to_pascal_case(field, context.temp_allocator))); !ok {
		return mcp.tool_fail("bad_value", "%s", why)
	}
	return mcp.tool_ok(struct {
		field: string,
		value: [3]f32,
	}{field = field, value = v})
}

// A component on an object, named the way list_objects prints it. An empty or
// "Transform" name is the transform itself.
@(private = "file")
_mcp_find_property :: proc(params: json.Object) -> (inspector.Property, Mcp_Error) {
	tH, ferr := _mcp_find_object(params)
	if ferr.code != "" do return {}, ferr
	comp_name, _ := params["component"].(json.String)
	path, _ := params["path"].(json.String) // empty: the whole component

	root: inspector.Property
	if comp_name == "" || comp_name == "Transform" {
		p, ok := inspector.inspect_transform(tH)
		if !ok do return {}, Mcp_Error{"not_found", "object went away"}
		root = p
	} else {
		w := engine.ctx_world()
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do return {}, Mcp_Error{"not_found", "object went away"}
		found := false
		for c in t.components {
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			if tid == nil do continue
			if fmt.tprintf("%v", tid) != comp_name && fmt.tprintf("%v", c.handle.type_key) != comp_name do continue
			p, ok := inspector.inspect_comp(c.handle)
			if !ok do return {}, Mcp_Error{"not_found", "component went away"}
			root = p
			found = true
			break
		}
		if !found do return {}, Mcp_Error{"not_found", fmt.tprintf("object has no component %q — see list_objects", comp_name)}
	}
	prop, err := inspector.property(root, path)
	if err != .None do return {}, Mcp_Error{"bad_path", fmt.tprintf("%s: %v", path, err)}
	return prop, {}
}

@(mcp_tool={
	description="Read a component (or the transform) on an object as JSON, or one field of it. Address the object by local_id (preferred) or exact name, the component as list_objects prints it. Omit path for the whole component — the way to learn its field names — or give a dotted path with [i] for array elements, e.g. color, layers[0].states[1].speed.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact object name (alternative to local_id)",
	param_component="string:Component type as list_objects prints it; omit or Transform for the transform",
	param_path="string:Field path, dot-separated, [i] indexes an array; omit for the whole component",
})
mcp_tool_get_property :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	p, perr := _mcp_find_property(params)
	if perr.code != "" do return "", perr
	bytes := inspector.property_get_json(p)
	defer delete(bytes)
	path, _ := params["path"].(json.String)
	return mcp.tool_ok(struct {
		path:  string,
		type:  string,
		value: json.Value,
	}{path = path, type = fmt.tprintf("%v", p.tid), value = _mcp_parse_value(bytes)})
}

@(mcp_tool={
	description="Set one field of a component (or the transform) on an object. Same addressing as get_property. The value is JSON in the field's own shape — get_property shows it. A reference field accepts only what its ref: tag admits, as the picker does. One undo step. On a prefab instance the write records an override on the field, or on the whole array when the path indexes one.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact object name (alternative to local_id)",
	param_component="string:Component type as list_objects prints it; omit or Transform for the transform",
	param_path="string!:Field path, dot-separated, [i] indexes an array",
	param_value="string!:JSON-encoded value, e.g. 2.5, true, [1,0,0,1], {\"local_id\":12}",
})
mcp_tool_set_property :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	p, perr := _mcp_find_property(params)
	if perr.code != "" do return "", perr
	value, has_value := params["value"].(json.String)
	if !has_value do return mcp.tool_fail("bad_request", "need value (JSON-encoded, as a string)")
	path, _ := params["path"].(json.String)
	if path == "" do return mcp.tool_fail("bad_request", "set needs a field path — a whole component is not assignable")
	if ok, why := inspector.property_set_json(p, transmute([]byte)string(value), fmt.tprintf("Set %s (MCP)", path)); !ok {
		return mcp.tool_fail("bad_value", "%s: %s", value, why)
	}
	bytes := inspector.property_get_json(p)
	defer delete(bytes)
	return mcp.tool_ok(struct {
		path:  string,
		value: json.Value,
	}{path = path, value = _mcp_parse_value(bytes)})
}

// Captured field bytes as a json.Value, so the reply nests the value instead
// of quoting it. Temp-allocated.
@(private = "file")
_mcp_parse_value :: proc(bytes: []byte) -> json.Value {
	v, err := json.parse(bytes, allocator = context.temp_allocator)
	if err != nil do return json.String(string(bytes))
	return v
}

@(mcp_tool={
	description="Rename one object. Address it by local_id (preferred) or exact current name. One undo step.",
	param_local_id="integer:Object local_id from list_objects",
	param_name="string:Exact current name (alternative to local_id)",
	param_new_name="string!:The new name",
})
mcp_tool_rename_object :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	tH, ferr := _mcp_find_object(params)
	if ferr.code != "" do return "", ferr
	new_name, has := params["new_name"].(json.String)
	if !has || new_name == "" do return mcp.tool_fail("bad_request", "need new_name")

	// Through the property path, so a rename on prefab-instance content records
	// the override the inspector's name field would.
	p, pok := inspector.inspect_transform(tH)
	if !pok do return mcp.tool_fail("not_found", "object went away")
	np, _ := inspector.property(p, "name")
	encoded, merr := json.marshal(new_name, {}, context.temp_allocator)
	if merr != nil do return mcp.tool_fail("bad_value", "could not encode name")
	if ok, why := inspector.property_set_json(np, encoded, "Rename (MCP)"); !ok {
		return mcp.tool_fail("bad_value", "%s", why)
	}
	return mcp.tool_ok(struct{ name: string }{new_name})
}
