package tests

// MCP tool handlers (editor/mcp_bridge.odin). The wire framing is covered by
// mcp_protocol_tests; this is what the tools themselves answer.
//
// Two properties matter enough to pin: a listing is BOUNDED (a scene's worth
// of objects in one reply is most of an agent's context), and a batch runs the
// same code a standalone call runs.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "../editor"
import "../editor/undo"
import "../engine"

@(private = "file")
_tool :: proc(t: ^testing.T, name: string, params: json.Object) -> (json.Object, bool) {
	out, err := editor.mcp_tool_for_test(name, params)
	if err.code != "" {
		testing.expectf(t, false, "%s failed: %s: %s", name, err.code, err.message)
		return nil, false
	}
	// parse_integers, or every count comes back as a Float and the assertions
	// below silently read zero.
	v, perr := json.parse(transmute([]byte)out, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil {
		testing.expectf(t, false, "%s returned unparseable JSON", name)
		return nil, false
	}
	obj, is_obj := v.(json.Object)
	return obj, is_obj
}

@(private = "file")
_params :: proc(pairs: ..struct{k: string, v: json.Value}) -> json.Object {
	o := make(json.Object, len(pairs), context.temp_allocator)
	for p in pairs do o[p.k] = p.v
	return o
}

@(private = "file")
_scene_with_objects :: proc(tc: ^TestCtx, n: int) {
	root := engine.Transform_Handle(tc.scene.root.handle)
	for _ in 0 ..< n {
		engine.transform_new("Obj", root)
	}
}

// A listing never returns the whole scene at once: an agent asking what is in
// a scene should not pay for every object in it.
@(test)
test_list_objects_is_paginated :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.sm_scene_set_active(tc.scene)

	_scene_with_objects(tc, 120)

	first, ok := _tool(t, "list_objects", _params({"page_size", json.Integer(50)}))
	if !ok do return
	objs, _ := first["objects"].(json.Array)
	testing.expect_value(t, len(objs), 50)
	total, _ := first["total"].(json.Integer)
	testing.expect(t, total >= 120, "total counts every match, not the page")
	next, _ := first["next_cursor"].(json.Integer)
	testing.expect_value(t, next, json.Integer(50))

	// The cursor resumes where the page ended, and the last page says so.
	last, ok2 := _tool(t, "list_objects", _params(
		{"page_size", json.Integer(500)}, {"cursor", json.Integer(50)}))
	if !ok2 do return
	rest, _ := last["objects"].(json.Array)
	testing.expect_value(t, len(rest), int(total) - 50)
	end, _ := last["next_cursor"].(json.Integer)
	testing.expect_value(t, end, json.Integer(-1))

	// page_size is clamped, not trusted.
	huge, ok3 := _tool(t, "list_objects", _params({"page_size", json.Integer(99999)}))
	if !ok3 do return
	all, _ := huge["objects"].(json.Array)
	testing.expect(t, len(all) <= 500, "page_size is capped at 500")
}

// Positions are the bulk of a listing's bytes, so they are asked for.
@(test)
test_list_objects_position_is_opt_in :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.sm_scene_set_active(tc.scene)
	_scene_with_objects(tc, 1)

	plain, ok := _tool(t, "list_objects", nil)
	if !ok do return
	objs, _ := plain["objects"].(json.Array)
	testing.expect(t, len(objs) > 0)
	if len(objs) == 0 do return
	first, _ := objs[0].(json.Object)
	pos, _ := first["position"].(json.Array)
	testing.expect_value(t, len(pos), 0)
	_, has_comps := first["components"]
	testing.expect(t, has_comps, "components stay — they are how an agent picks what to read")

	detailed, ok2 := _tool(t, "list_objects", _params({"detail", json.Boolean(true)}))
	if !ok2 do return
	dobjs, _ := detailed["objects"].(json.Array)
	dfirst, _ := dobjs[0].(json.Object)
	dpos, has := dfirst["position"].(json.Array)
	testing.expect(t, has && len(dpos) == 3, "detail adds a world position")
}

// A full dump is the whole file. It is refused rather than silently enormous.
@(test)
test_scene_dump_full_is_size_capped :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)
	engine.sm_scene_set_active(tc.scene)
	_scene_with_objects(tc, 50)

	_, err := editor.mcp_tool_for_test("scene_dump", _params(
		{"full", json.Boolean(true)}, {"max_bytes", json.Integer(200)}))
	testing.expect_value(t, err.code, "too_large")

	// Raising the cap deliberately is how you get it anyway.
	big, ok := _tool(t, "scene_dump", _params(
		{"full", json.Boolean(true)}, {"max_bytes", json.Integer(10_000_000)}))
	if !ok do return
	_, has_scene := big["scene"].(json.String)
	testing.expect(t, has_scene, "an explicit cap still returns the dump")

	// The summary is never capped — it is bounded by construction.
	sum, ok2 := _tool(t, "scene_dump", nil)
	if !ok2 do return
	_, has_count := sum["transform_count"].(json.Integer)
	testing.expect(t, has_count)
}

@(test)
test_batch_runs_each_command :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	u := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, u)
	engine.sm_scene_set_active(tc.scene)

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := engine.transform_new("A", root)
	b := engine.transform_new("B", root)
	at := engine.pool_get(&tc.world.transforms, engine.Handle(a))
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(b))

	cmds := make(json.Array, 0, 2, context.temp_allocator)
	append(&cmds, json.Value(_params(
		{"tool", json.String("rename_object")},
		{"params", _params({"local_id", json.Integer(at.local_id)}, {"new_name", json.String("A2")})},
	)))
	append(&cmds, json.Value(_params(
		{"tool", json.String("rename_object")},
		{"params", _params({"local_id", json.Integer(bt.local_id)}, {"new_name", json.String("B2")})},
	)))

	res, ok := _tool(t, "batch", _params({"commands", cmds}))
	if !ok do return
	ran, _ := res["ran"].(json.Integer)
	failed, _ := res["failed"].(json.Integer)
	testing.expect_value(t, ran, json.Integer(2))
	testing.expect_value(t, failed, json.Integer(0))
	testing.expect_value(t, at.name, "A2")
	testing.expect_value(t, bt.name, "B2")

	// One undo step per command — a batch is a convenience, not a transaction.
	testing.expect(t, undo.apply_undo(u), "undo applies")
	testing.expect_value(t, bt.name, "B")
	testing.expect_value(t, at.name, "A2")
}

@(test)
test_batch_failure_modes :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	u := setup_undo(tc)
	context.user_ptr = &tc.uc
	defer teardown_undo(tc, u)
	engine.sm_scene_set_active(tc.scene)

	root := engine.Transform_Handle(tc.scene.root.handle)
	a := engine.transform_new("A", root)
	at := engine.pool_get(&tc.world.transforms, engine.Handle(a))

	bad := _params({"tool", json.String("no_such_tool")}, {"params", _params()})
	good := _params(
		{"tool", json.String("rename_object")},
		{"params", _params({"local_id", json.Integer(at.local_id)}, {"new_name", json.String("A2")})},
	)

	// fail_fast stops, and the command after the failure never runs.
	stop := make(json.Array, 0, 2, context.temp_allocator)
	append(&stop, json.Value(bad), json.Value(good))
	res, ok := _tool(t, "batch", _params({"commands", stop}))
	if !ok do return
	ran, _ := res["ran"].(json.Integer)
	early, _ := res["stopped_early"].(json.Boolean)
	testing.expect_value(t, ran, json.Integer(1))
	testing.expect(t, bool(early), "fail_fast reports that it stopped")
	testing.expect_value(t, at.name, "A")

	// Without it, a failure is reported and the rest still runs.
	carry := make(json.Array, 0, 2, context.temp_allocator)
	append(&carry, json.Value(bad), json.Value(good))
	res2, ok2 := _tool(t, "batch", _params({"commands", carry}, {"fail_fast", json.Boolean(false)}))
	if !ok2 do return
	ran2, _ := res2["ran"].(json.Integer)
	failed2, _ := res2["failed"].(json.Integer)
	testing.expect_value(t, ran2, json.Integer(2))
	testing.expect_value(t, failed2, json.Integer(1))
	testing.expect_value(t, at.name, "A2")

	// A batch inside a batch would answer twice.
	nest := make(json.Array, 0, 1, context.temp_allocator)
	append(&nest, json.Value(_params({"tool", json.String("batch")}, {"params", _params()})))
	res3, ok3 := _tool(t, "batch", _params({"commands", nest}))
	if !ok3 do return
	results, _ := res3["results"].(json.Array)
	first, _ := results[0].(json.Object)
	msg, _ := first["message"].(json.String)
	testing.expect_value(t, string(msg), "batch cannot nest")

	// A handler that answers across frames cannot be batched either.
	shot := make(json.Array, 0, 1, context.temp_allocator)
	append(&shot, json.Value(_params({"tool", json.String("screenshot")}, {"params", _params()})))
	res4, ok4 := _tool(t, "batch", _params({"commands", shot}))
	if !ok4 do return
	r4, _ := res4["results"].(json.Array)
	f4, _ := r4[0].(json.Object)
	st4, _ := f4["status"].(json.String)
	testing.expect_value(t, string(st4), "error")

	// Over the cap the whole batch is refused, so nothing runs by halves.
	too_many := make(json.Array, 0, 101, context.temp_allocator)
	for _ in 0 ..< 101 do append(&too_many, json.Value(good))
	_, err := editor.mcp_tool_for_test("batch", _params({"commands", too_many}))
	testing.expect_value(t, err.code, "bad_request")
}

// describe_type answers from the live registry and Odin reflection, so an
// agent can check a field and what it admits before writing — the alternative
// is learning it from a failed set_property.
@(test)
test_describe_type_reports_fields_and_ref_tags :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	// No type: the catalogue.
	all, ok := _tool(t, "describe_type", nil)
	if !ok do return
	comps, _ := all["components"].(json.Array)
	testing.expect(t, len(comps) > 10, "every registered component is listed")
	found := false
	for c in comps {
		if s, is := c.(json.String); is && string(s) == "TimelineAnimator" do found = true
	}
	testing.expect(t, found, "a plugin's components are in the registry too")

	// A component: fields with types.
	ta, ok2 := _tool(t, "describe_type", _params({"type", json.String("TimelineAnimator")}))
	if !ok2 do return
	fields, _ := ta["fields"].(json.Array)
	layers_type := ""
	for f in fields {
		o, _ := f.(json.Object)
		n, _ := o["name"].(json.String)
		if string(n) == "layers" {
			ty, _ := o["type"].(json.String)
			layers_type = string(ty)
		}
	}
	testing.expect(t, strings.contains(layers_type, "Animator_Layer"), "a field reports its real type")

	// A path walks into the type and describes the ELEMENT, so the fields
	// listed are the ones a path like layers[0].states[1].x would address.
	st, ok3 := _tool(t, "describe_type", _params(
		{"type", json.String("TimelineAnimator")}, {"path", json.String("layers[0].states")}))
	if !ok3 do return
	elem, _ := st["element"].(json.String)
	testing.expect(t, strings.contains(string(elem), "Timeline_State"), "indices are ignored, the element is described")

	// The ref: tag is what set_property enforces, so it is reported here.
	sfields, _ := st["fields"].(json.Array)
	timeline_ref := ""
	for f in sfields {
		o, _ := f.(json.Object)
		n, _ := o["name"].(json.String)
		if string(n) == "timeline" {
			r, _ := o["ref"].(json.String)
			timeline_ref = string(r)
		}
	}
	testing.expect_value(t, timeline_ref, "PlayableDirector")

	// Indices are optional: the same type is reached without them.
	st2, ok4 := _tool(t, "describe_type", _params(
		{"type", json.String("TimelineAnimator")}, {"path", json.String("layers.states")}))
	if !ok4 do return
	elem2, _ := st2["element"].(json.String)
	testing.expect_value(t, string(elem2), string(elem))
}

@(test)
test_describe_type_rejects_what_does_not_exist :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc, "")
	context.user_ptr = &tc.uc
	defer teardown(tc)

	_, e1 := editor.mcp_tool_for_test("describe_type", _params({"type", json.String("NotAComponent")}))
	testing.expect_value(t, e1.code, "not_found")

	_, e2 := editor.mcp_tool_for_test("describe_type", _params(
		{"type", json.String("TimelineAnimator")}, {"path", json.String("layers.nope")}))
	testing.expect_value(t, e2.code, "bad_path")
}
