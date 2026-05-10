package tests

import "../engine"

import "core:testing"
import "core:strings"
import "core:encoding/json"

// Helpers ---------------------------------------------------------------------

@(private = "file")
find_override :: proc(ovs: []engine.Override, target_lid: engine.Local_ID, path: string) -> (engine.Override, bool) {
	for ov in ovs {
		if ov.target.local_id == target_lid && strings.compare(ov.property_path, path) == 0 {
			return ov, true
		}
	}
	return {}, false
}

@(private = "file")
override_matches_path :: proc(ovs: []engine.Override, target_lid: engine.Local_ID, path_prefix: string) -> bool {
	for ov in ovs {
		if ov.target.local_id != target_lid do continue
		if strings.has_prefix(ov.property_path, path_prefix) do return true
	}
	return false
}

// Diff allocates property_path via strings.clone and value via json.clone_value.
// Tests own the returned dynamic array, so they must release both per element.
@(private = "file")
free_overrides :: proc(ovs: ^[dynamic]engine.Override) {
	for &ov in ovs {
		delete(ov.property_path)
		json.destroy_value(ov.value)
	}
	delete(ovs^)
}

// Diff -----------------------------------------------------------------------

// Doc lines 81-82: "Entire array as one atomic override. Never override
// individual elements. If anything inside the array changes, the whole array
// is the override value." Diff must NOT produce indexed paths like "tags.0".
@(test)
test_diff_overrides_array_atomic :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"tags":["a","b","c"]}]}`
	work := `{"transforms":[{"local_id":1,"tags":["a","b","X"]}]}`

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&out)

	testing.expect_value(t, len(out), 1)
	if len(out) != 1 do return
	ov := out[0]
	testing.expect_value(t, ov.target.local_id, engine.Local_ID(1))
	testing.expect_value(t, ov.property_path, "tags")

	arr, is_arr := ov.value.(json.Array)
	testing.expect(t, is_arr, "atomic array override must carry the whole new array as value")
	if !is_arr do return
	testing.expect_value(t, len(arr), 3)
	last, last_ok := arr[2].(json.String)
	testing.expect(t, last_ok && string(last) == "X")
}

// Doc-derived: "parent", "children", "components" are top-level structure that
// the editor never persists as overrides; "local_id" is identity, never an
// override. Verified at nested_scene.odin:_DIFF_TOP_EXCLUDED / _DIFF_ALWAYS_EXCLUDED.
@(test)
test_diff_overrides_excluded_keys :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"parent":7,"children":[10,11],"components":[100],"position":[0,0,0]}]}`
	work := `{"transforms":[{"local_id":1,"parent":42,"children":[99],"components":[200],"position":[1,2,3]}]}`

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&out)

	testing.expect(t, !override_matches_path(out[:], 1, "parent"),
		"parent must not appear in overrides")
	testing.expect(t, !override_matches_path(out[:], 1, "children"),
		"children must not appear in overrides")
	testing.expect(t, !override_matches_path(out[:], 1, "components"),
		"components must not appear in overrides")
	testing.expect(t, !override_matches_path(out[:], 1, "local_id"),
		"local_id must never appear in overrides")

	_, has_pos := find_override(out[:], 1, "position")
	testing.expect(t, has_pos, "non-excluded property change should still produce an override")
}

// Diff descends into nested objects and emits dot-separated property paths for
// scalar leaves. Required by revert and apply, both of which look up values by
// dotted path.
@(test)
test_diff_overrides_dotted_path_for_nested_scalar :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":2,"meta":{"color":{"r":0.0,"g":0.5,"b":1.0}}}]}`
	work := `{"transforms":[{"local_id":2,"meta":{"color":{"r":0.0,"g":0.9,"b":1.0}}}]}`

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&out)

	ov, ok := find_override(out[:], 2, "meta.color.g")
	testing.expect(t, ok, "expected dotted path override for nested scalar")
	if !ok do return
	#partial switch n in ov.value {
	case json.Float:   testing.expect(t, n == 0.9)
	case json.Integer: testing.expect(t, false, "expected float value, got integer")
	case:              testing.expect(t, false, "expected json.Float for nested scalar override")
	}
	testing.expect(t, !override_matches_path(out[:], 2, "meta.color.r"))
	testing.expect(t, !override_matches_path(out[:], 2, "meta.color.b"))
}

// No diff between identical inputs => no overrides. Guards against false
// positives that would inflate the override list across saves.
@(test)
test_diff_overrides_identical_inputs_yield_empty :: proc(t: ^testing.T) {
	doc := `{"transforms":[{"local_id":1,"position":[1,2,3]}]}`
	out := engine.nested_scene_diff_overrides(transmute([]byte)doc, transmute([]byte)doc)
	defer free_overrides(&out)
	testing.expect_value(t, len(out), 0)
}

// Diff scopes to matching local_id within section arrays — a row that exists
// only in `work` (not in `base`) should not be diffed against an unrelated row.
@(test)
test_diff_overrides_skips_unmatched_target :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"position":[0,0,0]}]}`
	work := `{"transforms":[{"local_id":1,"position":[0,0,0]},{"local_id":99,"position":[5,5,5]}]}`

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&out)

	for ov in out {
		testing.expect(t, ov.target.local_id != 99, "row with no base counterpart must produce no override")
	}
}

// Apply ----------------------------------------------------------------------

// Round-trip: apply(base, diff(base, work)) should produce JSON whose contents
// match `work` for the overridden field. Confirms diff and apply agree on
// property_path semantics.
@(test)
test_apply_then_diff_roundtrip :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"position":[0,0,0]}]}`
	work := `{"transforms":[{"local_id":1,"position":[10,20,30]}]}`

	overrides := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&overrides)
	testing.expect_value(t, len(overrides), 1)

	baked := engine.nested_scene_apply_overrides(transmute([]byte)base, overrides[:])
	// nested_scene_apply_overrides may return a freshly-allocated buffer or the
	// input if nothing changed; only delete when distinct.
	defer if &baked[0] != &(transmute([]byte)base)[0] do delete(baked)

	// Re-diff baked vs work — should now be empty.
	roundtrip := engine.nested_scene_diff_overrides(baked, transmute([]byte)work)
	defer free_overrides(&roundtrip)
	testing.expect_value(t, len(roundtrip), 0)
}

// Empty override list is a no-op: apply returns input unchanged.
@(test)
test_apply_overrides_empty_list_passthrough :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"position":[0,0,0]}]}`
	out := engine.nested_scene_apply_overrides(transmute([]byte)base, []engine.Override{})
	testing.expect_value(t, string(out), base)
}

// Diff is one-way: it captures changes from base to work. A row that exists
// only in `base` (i.e. removed in work) does not produce a "delete" override —
// the override format has no representation for it. Verify diff stays silent
// rather than emitting spurious overrides for the orphan row.
@(test)
test_diff_overrides_skips_rows_only_in_base :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"position":[0,0,0]},{"local_id":7,"position":[5,5,5]}]}`
	work := `{"transforms":[{"local_id":1,"position":[0,0,0]}]}`

	out := engine.nested_scene_diff_overrides(transmute([]byte)base, transmute([]byte)work)
	defer free_overrides(&out)

	for ov in out {
		testing.expect(t, ov.target.local_id != 7,
			"row removed in work must not produce overrides against the absent target")
	}
}

// Apply must not corrupt JSON when an override targets a local_id that no
// longer exists in the base. This happens after a prefab is edited to remove
// a sub-object — the saved override on the host scene becomes orphaned.
// Expectation: the orphaned override is silently skipped, the rest of the
// document round-trips intact.
@(test)
test_apply_overrides_missing_target_is_noop :: proc(t: ^testing.T) {
	base := `{"transforms":[{"local_id":1,"position":[0,0,0]}]}`
	overrides := []engine.Override{
		{ target = engine.PPtr{local_id = 999}, property_path = "position", value = json.Array{} },
	}
	out := engine.nested_scene_apply_overrides(transmute([]byte)base, overrides)
	defer if &out[0] != &(transmute([]byte)base)[0] do delete(out)

	// Re-parse the result and confirm the only transform's position is
	// untouched. We don't assert byte-for-byte equality with `base` because
	// apply re-marshals.
	val: json.Value
	defer json.destroy_value(val)
	testing.expect(t, json.unmarshal(out, &val) == nil, "result must be valid JSON")
	root, is_obj := val.(json.Object)
	testing.expect(t, is_obj)
	if !is_obj do return
	transforms, has_t := root["transforms"]
	testing.expect(t, has_t)
	arr, is_arr := transforms.(json.Array)
	testing.expect(t, is_arr && len(arr) == 1)
	if !is_arr || len(arr) != 1 do return
	row, is_row := arr[0].(json.Object)
	testing.expect(t, is_row)
	if !is_row do return
	pos, has_pos := row["position"]
	testing.expect(t, has_pos)
	testing.expect(t, override_vec3_matches(pos, {0, 0, 0}))
}

// has_override: simple membership check on (target, path). Guards against
// future regressions where revert might add it back to the list.
@(test)
test_nested_scene_has_override_membership :: proc(t: ^testing.T) {
	ns := engine.NestedScene{}
	defer delete(ns.overrides)
	tgt5 := engine.PPtr{local_id = 5}
	tgt6 := engine.PPtr{local_id = 6}
	append(&ns.overrides, engine.Override{target = tgt5, property_path = "position"})

	testing.expect(t, engine.nested_scene_has_override(&ns, tgt5, "position"))
	testing.expect(t, !engine.nested_scene_has_override(&ns, tgt5, "rotation"))
	testing.expect(t, !engine.nested_scene_has_override(&ns, tgt6, "position"))
	testing.expect(t, !engine.nested_scene_has_override(nil, tgt5, "position"))
}
