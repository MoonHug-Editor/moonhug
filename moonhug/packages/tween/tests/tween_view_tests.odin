package tween_tests

// The graph view's root discovery over authored blobs: every Authored field
// in a component's value graph, in walk order (field order + array order).

import tween "moonhug:packages/tween"
import tween_editor "moonhug:packages/tween/editor"
import common "moonhug:tests/common"
import "core:testing"

_View_Holder :: struct {
	direct: tween.Authored,
	pair:   [2]tween.Authored,
	inner:  struct {
		held: tween.Authored,
	},
}

@(test)
test_tween_roots_walk_order :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	h: _View_Holder
	h.direct = tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}})
	h.pair[0] = tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}})
	h.pair[1] = tween.authored(tween.TweenRotateToLocal{duration = 1})
	h.inner.held = tween.authored(tween.Sequence{}, {
		tween.authored(tween.TweenMoveToLocal{position = {9, 9, 9}}),
	})
	defer {
		tween.authored_destroy(&h.direct)
		tween.authored_destroy(&h.pair[0])
		tween.authored_destroy(&h.pair[1])
		tween.authored_destroy(&h.inner.held)
	}

	roots := tween_editor.tween_roots_of(&h, typeid_of(_View_Holder))
	testing.expect_value(t, len(roots), 4)
	if len(roots) < 4 do return

	testing.expect(t, roots[0] == &h.direct, "walk order: direct field first")
	testing.expect(t, roots[1] == &h.pair[0], "walk order: fixed array in order")
	testing.expect(t, roots[2] == &h.pair[1], "walk order: fixed array in order")
	testing.expect(t, roots[3] == &h.inner.held, "walk order: nested struct last")

	tid, ok := tween.authored_typeid(roots[3].value)
	testing.expect(t, ok && tid == typeid_of(tween.Sequence), "root type resolves through the guid")
	kids, kok := tween.authored_children(roots[3].value)
	testing.expect(t, kok && len(kids) == 1, "children nest inside the blob")
}
