package tween_tests

// The Tween Graph window's root discovery over authored blobs: every Authored field
// in a component's value graph, in walk order (field order + array order).

import tween "moonhug:packages/tween"
import tween_editor "moonhug:packages/tween/editor"
import common "moonhug:tests/common"
import "core:testing"

_Tween_Holder :: struct {
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

	h: _Tween_Holder
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

	roots := tween_editor.tween_roots_of(&h, typeid_of(_Tween_Holder))
	testing.expect_value(t, len(roots), 4)
	if len(roots) < 4 do return

	testing.expect(t, roots[0] == &h.direct, "walk order: direct field first")
	testing.expect(t, roots[1] == &h.pair[0], "walk order: fixed array in order")
	testing.expect(t, roots[2] == &h.pair[1], "walk order: fixed array in order")
	testing.expect(t, roots[3] == &h.inner.held, "walk order: nested struct last")

	tid, ok := tween.authored_typeid(roots[3].value)
	testing.expect(t, ok && tid == typeid_of(tween.Sequence), "root type resolves through the guid")
	children, kok := tween.authored_children(roots[3].value)
	testing.expect(t, kok && len(children) == 1, "children nest inside the blob")
}

_Tween_Listed :: struct {
	speed: f32,
	list:  [dynamic]tween.Authored,
	inner: struct {
		held: tween.Authored,
	},
}

// Each root's field path: a field by name, an array element by its index in
// the array, so an empty slot before it leaves the path as it is.
@(test)
test_tween_roots_paths :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	h: _Tween_Listed
	append(&h.list, tween.Authored{}) // an empty slot
	append(&h.list, tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}}))
	h.inner.held = tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}})
	defer {
		for &a in h.list do tween.authored_destroy(&a)
		delete(h.list)
		tween.authored_destroy(&h.inner.held)
	}

	roots, paths := tween_editor.tween_roots_with_paths(&h, typeid_of(_Tween_Listed))
	testing.expect_value(t, len(roots), 2)
	testing.expect_value(t, len(paths), 2)
	if len(paths) < 2 do return
	testing.expect_value(t, paths[0], "list[1]")
	testing.expect_value(t, paths[1], "inner.held")
	testing.expect(t, roots[0] == &h.list[1], "the path names the element it was found at")
}

_Plain_Points :: struct {
	points: [dynamic][3]f32,
	scale:  f32,
}

_Holds_Self :: struct {
	kids: [dynamic]_Holds_Self,
	tree: tween.Authored,
}

_Plain_Self :: struct {
	kids: [dynamic]_Plain_Self,
	x:    f32,
}

_Cycle_A :: struct {
	wraps: [dynamic]_Cycle_B,
	tree:  tween.Authored,
}

_Cycle_B :: struct {
	back: [dynamic]_Cycle_A,
}

_Tween_Or_Plain :: union {
	f32,
	tween.Authored,
}

// Whether a type can hold a tween, the walk's skip test: a type with no
// Authored anywhere is skipped whole, and a type that holds itself through
// an array gets the same answer as any other.
@(test)
test_type_holds_tweens :: proc(t: ^testing.T) {
	holds :: proc(T: typeid) -> bool { return tween_editor.type_holds_tweens(type_info_of(T)) }
	testing.expect(t, holds(_Tween_Holder), "fields, a fixed array and a nested struct hold tweens")
	testing.expect(t, holds(_Tween_Listed), "a dynamic array of Authored holds tweens")
	testing.expect(t, !holds(_Plain_Points), "plain data holds none")
	testing.expect(t, holds(_Holds_Self), "a type that holds itself and a tween")
	testing.expect(t, !holds(_Plain_Self), "a type that holds itself and no tween")
	testing.expect(t, holds(_Tween_Or_Plain), "a union with an Authored variant")
	// B is worked out while A is, and reaches A before A's answer is known:
	// B's answer must not be kept from that moment.
	testing.expect(t, holds(_Cycle_A), "A holds a tween")
	testing.expect(t, holds(_Cycle_B), "B holds one through A")
}
