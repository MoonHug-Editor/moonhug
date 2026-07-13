package tests

// Sprite sort key tests (engine/sprite_sort.odin): Unity semantics —
// sorting_layer -> order_in_layer -> view depth back-to-front -> tree order —
// with SpriteSortingGroup subtrees sorting as one unit against outsiders.
// Pure data tests: build a scene tree, run the key pass, assert key ordering.

import "../engine"

import "core:math/linalg"
import "core:testing"

// Camera at +Z looking at the origin: a transform's view depth equals its
// distance along -Z from the camera (z=0 => depth 10, z=5 => depth 5).
@(private = "file")
_sort_test_view :: proc() -> engine.Render_View {
	view := linalg.matrix4_look_at_f32({0, 0, 10}, {0, 0, 0}, {0, 1, 0})
	return engine.render_view_make(view, linalg.MATRIX4F32_IDENTITY, 100, 100, ~u32(0))
}

@(private = "file")
_sprite_at :: proc(parent: engine.Transform_Handle, name: string, z: f32, layer: i32 = 0, order: i32 = 0) -> engine.Transform_Handle {
	h := engine.transform_new(name, parent)
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
	t.position = {0, 0, z}
	_, sr := engine.transform_get_or_add_comp(h, engine.SpriteRenderer)
	sr.sorting_layer = layer
	sr.order_in_layer = order
	return h
}

@(private = "file")
_group_at :: proc(parent: engine.Transform_Handle, name: string, z: f32, layer: i32 = 0, order: i32 = 0) -> engine.Transform_Handle {
	h := engine.transform_new(name, parent)
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(h))
	t.position = {0, 0, z}
	_, g := engine.transform_get_or_add_comp(h, engine.SpriteSortingGroup)
	g.sorting_layer = layer
	g.order_in_layer = order
	return h
}

// keys[a] sorts before keys[b] => a draws first (further back).
@(private = "file")
_draws_before :: proc(t: ^testing.T, keys: map[engine.Transform_Handle]engine.Sprite_Sort_Key, a, b: engine.Transform_Handle, msg: string) {
	ka, a_ok := keys[a]
	kb, b_ok := keys[b]
	testing.expect(t, a_ok && b_ok, "both sprites must have keys")
	testing.expectf(t, engine.sprite_sort_key_less(ka, kb), "expected draw order violated: %s", msg)
}

@(test)
test_sprite_sort_layer_order_depth_tree :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	// Layer beats everything: near sprite on layer 0 draws before far sprite
	// on layer 1 (higher layer draws on top = later).
	near_l0 := _sprite_at(rootH, "near_l0", 8, layer = 0)  // depth 2
	far_l1 := _sprite_at(rootH, "far_l1", 0, layer = 1)    // depth 10
	// Order in layer beats depth: same layer, near+order0 before far+order1.
	near_o0 := _sprite_at(rootH, "near_o0", 8, layer = 5, order = 0)
	far_o1 := _sprite_at(rootH, "far_o1", 0, layer = 5, order = 1)
	// Depth back-to-front within same layer/order.
	far_plain := _sprite_at(rootH, "far_plain", 0, layer = 9)  // depth 10
	near_plain := _sprite_at(rootH, "near_plain", 8, layer = 9) // depth 2
	// Tree order tiebreak: identical keys otherwise -> creation order.
	twin_a := _sprite_at(rootH, "twin_a", 3, layer = 9)
	twin_b := _sprite_at(rootH, "twin_b", 3, layer = 9)

	keys := engine.sprite_sort_build_keys(_sort_test_view())
	_draws_before(t, keys, near_l0, far_l1, "lower sorting_layer draws first")
	_draws_before(t, keys, near_o0, far_o1, "lower order_in_layer draws first within a layer")
	_draws_before(t, keys, far_plain, near_plain, "farther sprite draws first within same layer/order")
	_draws_before(t, keys, twin_a, twin_b, "equal keys fall back to tree order")
}

@(test)
test_sprite_sorting_group_is_atomic :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	// Two "characters": group A (order 0) with a HIGH-order member, group B
	// (order 1) with a LOW-order member. Without groups the members would
	// interleave (a_top after b_bottom); with groups ALL of A draws before
	// ALL of B — the group key wins the comparison.
	group_a := _group_at(rootH, "group_a", 0, order = 0)
	a_bottom := _sprite_at(group_a, "a_bottom", 0, order = 0)
	a_top := _sprite_at(group_a, "a_top", 0, order = 100)
	group_b := _group_at(rootH, "group_b", 0, order = 1)
	b_bottom := _sprite_at(group_b, "b_bottom", 0, order = 0)

	// An outsider between the groups by order.
	outsider := _sprite_at(rootH, "outsider", 0, order = 0)

	keys := engine.sprite_sort_build_keys(_sort_test_view())
	_draws_before(t, keys, a_top, b_bottom, "group A member (any order) draws before group B members")
	_draws_before(t, keys, a_bottom, a_top, "members sort by their own order inside the group")
	_draws_before(t, keys, outsider, b_bottom, "ungrouped order 0 draws before group with order 1")

	// The group's own transform can carry a sprite: it sorts inside the group.
	_, g_sr := engine.transform_get_or_add_comp(group_a, engine.SpriteRenderer)
	g_sr.order_in_layer = 50
	keys2 := engine.sprite_sort_build_keys(_sort_test_view())
	_draws_before(t, keys2, a_bottom, group_a, "group-root sprite sorts within its own group")
	_draws_before(t, keys2, group_a, a_top, "group-root sprite ordered by its own key inside")
}

@(test)
test_sprite_sorting_group_nesting_and_disable :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)

	// Nested groups: outer(order 0) contains inner_hi(order 10){member order 0}
	// and inner_lo(order 0){member order 100}. The inner groups sort as units
	// by THEIR order inside outer: all of inner_lo before all of inner_hi.
	outer := _group_at(rootH, "outer", 0, order = 0)
	inner_hi := _group_at(outer, "inner_hi", 0, order = 10)
	hi_member := _sprite_at(inner_hi, "hi_member", 0, order = 0)
	inner_lo := _group_at(outer, "inner_lo", 0, order = 0)
	lo_member := _sprite_at(inner_lo, "lo_member", 0, order = 100)

	keys := engine.sprite_sort_build_keys(_sort_test_view())
	_draws_before(t, keys, lo_member, hi_member, "nested groups sort as units by group order")

	// Disabled group stops grouping: hi_member falls back to the outer
	// context, competing at inner_lo's level — orders tie (0 vs 0), so tree
	// order decides and hi_member (earlier in the tree) now draws FIRST,
	// flipping the grouped result above.
	_, g := engine.transform_get_or_add_comp(inner_hi, engine.SpriteSortingGroup)
	g.enabled = false
	keys2 := engine.sprite_sort_build_keys(_sort_test_view())
	_draws_before(t, keys2, hi_member, lo_member, "disabled group's member falls back to outer context (tree order vs inner_lo unit)")
}

@(test)
test_sprite_sort_group_survives_scene_load :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_sort_group_load.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	group := _group_at(rootH, "grp", 0, order = 1)
	_ = _sprite_at(group, "member", 0, order = 0)
	outsider := _sprite_at(rootH, "outsider", 0, order = 0)
	_ = outsider

	testing.expect(t, engine.scene_save(tc_mem.scene, tc_mem.path), "scene_save should succeed")
	loaded := engine.scene_load_single_path(tc_mem.path)
	testing.expect(t, loaded != nil, "scene_load should return non-nil")
	tc_mem.scene = loaded

	w := engine.ctx_world()
	l_group := find_transform_named(w, loaded, "grp", false)
	l_member := find_transform_named(w, loaded, "member", false)
	l_outsider := find_transform_named(w, loaded, "outsider", false)
	testing.expect(t, l_member != {} && l_outsider != {} && l_group != {}, "loaded transforms found")

	keys := engine.sprite_sort_build_keys(_sort_test_view())
	k_member, m_ok := keys[l_member]
	_, o_ok := keys[l_outsider]
	testing.expect(t, m_ok && o_ok, "loaded sprites must be reached by the tree pass (not orphans)")
	// Grouped member has TWO key levels filled (group word + own word).
	testing.expect(t, k_member[1] != 0, "member's key must carry the group level after load")
	_draws_before(t, keys, l_outsider, l_member, "outsider (order 0) draws before grouped member (group order 1)")
}

// Child refs at nested-scene/variant boundaries carry pptr-only refs (runtime
// handles are json:"-" and not always fixed up). The tree pass must resolve
// them like the hierarchy view does, or grouped sprites silently degrade to
// ungrouped orphan keys and groups interleave.
@(test)
test_sprite_sort_group_reaches_children_with_stale_handles :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	rootH := engine.Transform_Handle(tc_mem.scene.root.handle)
	group := _group_at(rootH, "grp", 0, order = 1)
	member := _sprite_at(group, "member", 0, order = 0)

	// Simulate the loaded/nested state: the group's child ref keeps its
	// local_id but loses its runtime handle.
	w := engine.ctx_world()
	gt := engine.pool_get(&w.transforms, engine.Handle(group))
	testing.expect(t, len(gt.children) == 1)
	gt.children[0].handle = {}

	keys := engine.sprite_sort_build_keys(_sort_test_view())
	k_member, ok := keys[member]
	testing.expect(t, ok, "member with stale child ref must still be reached by the tree pass")
	testing.expect(t, ok && k_member[1] != 0, "member's key must carry the group level")
}
