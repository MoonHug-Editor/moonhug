package sprites

// Sprite sort keys — Unity semantics on data-oriented plumbing:
//   sorting_layer -> order_in_layer -> view depth back-to-front -> tree order
// Each hierarchy level packs into one u64 word:
//   layer:8 (biased) | order:16 (biased) | ~depth:24 (quantized, inverted so
//   farther sorts first) | tree_seq:16
// A SpriteSortingGroup contributes ITS word for the whole subtree, so the
// group sorts as one unit against outsiders while members keep sorting among
// themselves via the next level's word. Keys compare lexicographically over
// levels (engine.sort_key_less). tree_seq makes every word unique within a
// frame -> total order: deterministic frames, and untouched siblings draw in
// scene-tree order (Godot-style subtree atomicity) because all other bits tie.
//
// Resolution is ONE scene-tree pass per view (sprite_sort_build_keys), called
// by the sprite collector — O(n), no per-sprite ancestor walks.

import "moonhug:engine"

// Level words pack with the shared transparent-sort convention
// (engine.sort_key_word).
_sprite_view_depth :: proc(view: engine.Render_View, tH: engine.Transform_Handle) -> f32 {
	return engine.sort_key_depth(view, engine.transform_world(tH).position)
}

// Fallback for sprites not reached by the tree pass (owner outside any loaded
// scene): own word only, ordered after tree-reached peers with equal keys.
sprite_sort_orphan_key :: proc(view: engine.Render_View, sr: ^SpriteRenderer) -> engine.Sort_Key {
	key: engine.Sort_Key
	key[0] = engine.sort_key_word(sr.sorting_layer, sr.order_in_layer,
		_sprite_view_depth(view, engine.Transform_Handle(sr.owner)), max(u16))
	return key
}

// One pass over every loaded scene's tree: resolves each sprite owner's key
// with enclosing SpriteSortingGroups folded in. Map lives on `allocator`
// (temp by default — the render frame owns it).
sprite_sort_build_keys :: proc(view: engine.Render_View, allocator := context.temp_allocator) -> map[engine.Transform_Handle]engine.Sort_Key {
	keys := make(map[engine.Transform_Handle]engine.Sort_Key, allocator)
	sm := engine.ctx_scene_manager()
	if sm == nil do return keys

	w := engine.ctx_world()
	seq: u16 = 0
	chain: engine.Sort_Key
	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if !engine.sm_scene_is_valid(s) do continue
		if !engine.pool_valid(&w.transforms, s.root.handle) do continue
		_sprite_sort_visit(engine.Transform_Handle(s.root.handle), s, view, &keys, &seq, chain, 0)
	}
	return keys
}

_sprite_sort_visit :: proc(tH: engine.Transform_Handle, scene: ^engine.Scene, view: engine.Render_View, keys: ^map[engine.Transform_Handle]engine.Sort_Key, seq: ^u16, chain: engine.Sort_Key, level: int) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	// u16 wrap only matters past 65k tree nodes per view; ties then fall back
	// to sort order of equal keys (still deterministic input order).
	seq^ += 1
	node_seq := seq^

	chain := chain
	level := level

	// A group claims this level for its whole subtree; deeper groups beyond
	// capacity are ignored (outermost ones win the remaining levels).
	if _, group := get_comp(tH, SpriteSortingGroup); group != nil && group.enabled && level < engine.SORT_KEY_LEVELS - 1 {
		chain[level] = engine.sort_key_word(group.sorting_layer, group.order_in_layer, _sprite_view_depth(view, tH), node_seq)
		level += 1
	}

	if _, sr := get_comp(tH, SpriteRenderer); sr != nil {
		key := chain
		key[level] = engine.sort_key_word(sr.sorting_layer, sr.order_in_layer, _sprite_view_depth(view, tH), node_seq)
		keys[tH] = key
	}

	// Child refs may carry stale/empty runtime handles at nested-scene and
	// variant boundaries (handles are json:"-"); resolve like the hierarchy
	// view does — against the child's own scene when it has one — or missed
	// subtrees silently fall back to ungrouped orphan keys.
	sc := t.scene != nil ? t.scene : scene
	for child in t.children {
		ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
		if !ok do continue
		_sprite_sort_visit(ch, sc, view, keys, seq, chain, level)
	}
}
