package animation_tests

// The `ref:` field tag as a list, and the `@Tag` capability form
// (editor/inspector/ref_target.odin, docs/ObjectPicker.md).
//
// Lives with the animation package because Animation is the type that carries
// `ref_tags="Output"`, so `@Output` resolving to it is the end-to-end fact:
// attribute -> components_gen -> Component_Desc.ref_tags -> registry -> picker.

import "core:testing"
import "moonhug:editor/inspector"
import "moonhug:engine"
import common "moonhug:tests/common"

@(private = "file")
_has :: proc(keys: []engine.TypeKey, k: engine.TypeKey) -> bool {
	for have in keys do if have == k do return true
	return false
}

@(test)
test_ref_tag_resolves_a_type_name :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	keys := inspector.ref_target_keys("Animation")
	testing.expect_value(t, len(keys), 1)
	testing.expect(t, _has(keys, .Animation), "a type name resolves to its key")
}

// `@Output` is declared on Animation through its component attribute, so the
// tag has to reach the picker without the picker naming Animation anywhere.
@(test)
test_ref_tag_resolves_a_capability :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	keys := inspector.ref_target_keys("@Output")
	testing.expect(t, _has(keys, .Animation), "Animation carries ref_tags=Output")
	testing.expect(t, !_has(keys, .PlayableDirector), "an untagged type stays out")
}

// A list unions its items and names each key once, however many items admit it.
@(test)
test_ref_tag_list_unions_without_duplicates :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	keys := inspector.ref_target_keys(" Animation , @Output, PlayableDirector ")
	testing.expect(t, _has(keys, .Animation), "list includes the named type")
	testing.expect(t, _has(keys, .PlayableDirector), "list includes every named type")
	seen := 0
	for k in keys do if k == .Animation do seen += 1
	testing.expect_value(t, seen, 1)
}

// Nothing admitted means no picker, and a spec that names nothing real is
// treated the same — a typo in a tag must show, not silently list nothing.
@(test)
test_ref_tag_empty_and_unknown_resolve_to_nothing :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	testing.expect_value(t, len(inspector.ref_target_keys("")), 0)
	testing.expect_value(t, len(inspector.ref_target_keys("@NoSuchTag")), 0)
	testing.expect_value(t, len(inspector.ref_target_keys("NoSuchType")), 0)
	testing.expect_value(t, inspector.ref_target_missing_text("@Output"), "Missing (@Output)")
	testing.expect_value(t, inspector.ref_target_missing_text(""), "Missing")
}
