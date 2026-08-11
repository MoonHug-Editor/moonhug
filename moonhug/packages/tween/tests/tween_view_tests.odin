package tween_tests

// The Tween Graph's root discovery and locate, against locally-declared
// shapes. These import engine (the editor half's nature -- it draws engine
// tweens), unlike tween_tests.odin, which stays engine-free on purpose: that
// file is the proof the RUNTIME package needs no engine.
//
// The walks are pure reflection over type info plus live data, so no world,
// no registration and no runner are involved -- a test-local struct exercises
// every case, including a tween held in a different union's variant.

import tween_editor "moonhug:packages/tween/editor"
import "moonhug:engine"

import "core:testing"

_View_Level :: struct {
	name:  string,
	intro: engine.TweenUnion,
}

_View_Holder :: union {
	i64,
	engine.TweenUnion,
}

_View_Comp :: struct {
	pad:    [3]f32,
	levels: [dynamic]_View_Level,
	held:   _View_Holder,
	direct: engine.TweenUnion,
}

// Root discovery finds every TweenUnion at any depth, in deterministic walk
// order (field order, then array order).
@(test)
test_tween_roots_found_at_any_depth :: proc(t: ^testing.T) {
	c: _View_Comp
	c.levels = make([dynamic]_View_Level)
	defer delete(c.levels)
	append(&c.levels, _View_Level{intro = engine.TweenUnion(engine.TweenMoveToLocal{duration = 1})})
	append(&c.levels, _View_Level{intro = engine.TweenUnion(engine.TweenScaleToLocal{duration = 2})})
	c.held = engine.TweenUnion(engine.TweenRotateToLocal{duration = 3})
	c.direct = engine.TweenUnion(engine.TweenMoveToLocal{duration = 4})

	roots := tween_editor.tween_roots_of(&c, typeid_of(_View_Comp))

	testing.expect_value(t, len(roots), 4)
	testing.expect_value(t, roots[0], &c.levels[0].intro)
	testing.expect_value(t, roots[1], &c.levels[1].intro)
	testing.expect_value(t, roots[3], &c.direct)

	// A union-held root's ordinal round-trips through locate.
	idx, _, d, ok := tween_editor.tween_graph_locate_in(&c, typeid_of(_View_Comp), roots[2])
	testing.expect(t, ok, "union-held tween located")
	testing.expect_value(t, idx, 2)
	testing.expect_value(t, d, 0)
}

_View_Anims :: struct {
	animations: [dynamic]engine.TweenUnion,
}

// Locate names ANY node in a tree: (root ordinal, tree path). A nested child
// resolves to its containing root with the path marking the child, a root
// resolves with an empty path, and an unknown pointer reports failure rather
// than guessing.
@(test)
test_tween_graph_locate_finds_nested_node :: proc(t: ^testing.T) {
	c: _View_Anims
	c.animations = make([dynamic]engine.TweenUnion)
	defer delete(c.animations)

	// animations[0]: a bare leaf. animations[1]: Sequence -> [Move, Scale].
	append(&c.animations, engine.TweenUnion(engine.TweenMoveToLocal{duration = 1}))
	seq: engine.Sequence
	seq.children = make([dynamic]engine.TweenUnion)
	append(&seq.children, engine.TweenUnion(engine.TweenMoveToLocal{duration = 2}))
	append(&seq.children, engine.TweenUnion(engine.TweenScaleToLocal{duration = 3}))
	append(&c.animations, engine.TweenUnion(seq))
	defer {
		root := &c.animations[1].(engine.Sequence)
		delete(root.children)
	}

	root := &c.animations[1].(engine.Sequence)
	target := &root.children[1]

	root_idx, path, depth, ok := tween_editor.tween_graph_locate_in(&c, typeid_of(_View_Anims), target)
	testing.expect(t, ok, "nested node located")
	testing.expect_value(t, root_idx, 1)
	testing.expect_value(t, depth, 1)
	testing.expect_value(t, path[0], i32(1))

	r_idx, _, r_depth, r_ok := tween_editor.tween_graph_locate_in(&c, typeid_of(_View_Anims), &c.animations[0])
	testing.expect(t, r_ok, "root located")
	testing.expect_value(t, r_idx, 0)
	testing.expect_value(t, r_depth, 0)

	stray: engine.TweenUnion
	_, _, _, stray_ok := tween_editor.tween_graph_locate_in(&c, typeid_of(_View_Anims), &stray)
	testing.expect(t, !stray_ok, "unknown pointer is not located")
}
