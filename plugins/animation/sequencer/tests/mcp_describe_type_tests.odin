package animation_sequencer_tests

// The MCP describe_type tool (plugins/engine/editor/mcp_tools) on a plugin component
// with nested arrays and ref: tags (TimelineAnimator).

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "moonhug:editor"
import common "moonhug:tests/common"

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

// describe_type answers from the live registry and Odin reflection, so an
// agent can check a field and what it admits before writing — the alternative
// is learning it from a failed set_property.
@(test)
test_describe_type_reports_fields_and_ref_tags :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc, "")
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

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
