package engine

// Sprite sort keys — Unity semantics on data-oriented plumbing:
//   sorting_layer -> order_in_layer -> view depth back-to-front -> tree order
// Each hierarchy level packs into one u64 word:
//   layer:8 (biased) | order:16 (biased) | ~depth:24 (quantized, inverted so
//   farther sorts first) | tree_seq:16
// A SpriteSortingGroup contributes ITS word for the whole subtree, so the
// group sorts as one unit against outsiders while members keep sorting among
// themselves via the next level's word. Keys compare lexicographically over
// levels. tree_seq makes every word unique within a frame -> total order:
// deterministic frames, and untouched siblings draw in scene-tree order
// (Godot-style subtree atomicity) because all other bits tie.
//
// Resolution is ONE scene-tree pass per view (sprite_sort_build_keys), called
// by render_collect_commands — O(n), no per-sprite ancestor walks.

// 7 nested group levels + the sprite's own word (64-byte key). Deep enough
// for sprite-rigged characters (character > torso > arm > hand > item ...);
// each level costs 8 bytes per sprite command and one compare, so raise
// freely if content ever nests deeper.
SPRITE_SORT_LEVELS :: 8

Sprite_Sort_Key :: [SPRITE_SORT_LEVELS]u64

sprite_sort_key_less :: proc(a, b: Sprite_Sort_Key) -> bool {
	for i in 0 ..< SPRITE_SORT_LEVELS {
		if a[i] != b[i] do return a[i] < b[i]
	}
	return false
}

// One level word. Depth quantization: positive f32 bit patterns are monotonic
// as integers, so the top 24 bits of the view-space distance's bit pattern
// order correctly without knowing near/far; inverted so a larger distance
// (farther) yields a smaller word (drawn first, back-to-front).
_sprite_sort_word :: proc(layer, order: i32, view_depth: f32, seq: u16) -> u64 {
	l := u64(u32(clamp(layer, -128, 127) + 128))
	o := u64(u32(clamp(order, -32768, 32767) + 32768))
	d := u64(transmute(u32)max(view_depth, 0) >> 8) & 0xFFFFFF
	d = 0xFFFFFF - d
	return l << 56 | o << 40 | d << 16 | u64(seq)
}

// View-space distance of a transform's world position (same convention as the
// old per-sprite depth: right-handed view looks down -Z, larger = farther).
_sprite_view_depth :: proc(view: Render_View, tH: Transform_Handle) -> f32 {
	tw := transform_world(tH)
	pos4 := view.view * [4]f32{tw.position.x, tw.position.y, tw.position.z, 1}
	return -pos4.z
}

// Fallback for sprites not reached by the tree pass (owner outside any loaded
// scene): own word only, ordered after tree-reached peers with equal keys.
sprite_sort_orphan_key :: proc(view: Render_View, sr: ^SpriteRenderer) -> Sprite_Sort_Key {
	key: Sprite_Sort_Key
	key[0] = _sprite_sort_word(sr.sorting_layer, sr.order_in_layer,
		_sprite_view_depth(view, Transform_Handle(sr.owner)), max(u16))
	return key
}

// One pass over every loaded scene's tree: resolves each sprite owner's key
// with enclosing SpriteSortingGroups folded in. Map lives on `allocator`
// (temp by default — the render frame owns it).
sprite_sort_build_keys :: proc(view: Render_View, allocator := context.temp_allocator) -> map[Transform_Handle]Sprite_Sort_Key {
	keys := make(map[Transform_Handle]Sprite_Sort_Key, allocator)
	sm := ctx_scene_manager()
	if sm == nil do return keys

	w := ctx_world()
	seq: u16 = 0
	chain: Sprite_Sort_Key
	for i in 0 ..< sm.count {
		s := sm.loaded[i]
		if !sm_scene_is_valid(s) do continue
		if !pool_valid(&w.transforms, s.root.handle) do continue
		_sprite_sort_visit(Transform_Handle(s.root.handle), s, view, &keys, &seq, chain, 0)
	}
	return keys
}

_sprite_sort_visit :: proc(tH: Transform_Handle, scene: ^Scene, view: Render_View, keys: ^map[Transform_Handle]Sprite_Sort_Key, seq: ^u16, chain: Sprite_Sort_Key, level: int) {
	w := ctx_world()
	t := pool_get(&w.transforms, Handle(tH))
	if t == nil do return

	// u16 wrap only matters past 65k tree nodes per view; ties then fall back
	// to sort order of equal keys (still deterministic input order).
	seq^ += 1
	node_seq := seq^

	chain := chain
	level := level

	// A group claims this level for its whole subtree; deeper groups beyond
	// capacity are ignored (outermost ones win the remaining levels).
	if _, group := transform_get_comp(tH, SpriteSortingGroup); group != nil && group.enabled && level < SPRITE_SORT_LEVELS - 1 {
		chain[level] = _sprite_sort_word(group.sorting_layer, group.order_in_layer, _sprite_view_depth(view, tH), node_seq)
		level += 1
	}

	if _, sr := transform_get_comp(tH, SpriteRenderer); sr != nil {
		key := chain
		key[level] = _sprite_sort_word(sr.sorting_layer, sr.order_in_layer, _sprite_view_depth(view, tH), node_seq)
		keys[tH] = key
	}

	// Child refs may carry stale/empty runtime handles at nested-scene and
	// variant boundaries (handles are json:"-"); resolve like the hierarchy
	// view does — against the child's own scene when it has one — or missed
	// subtrees silently fall back to ungrouped orphan keys.
	sc := t.scene != nil ? t.scene : scene
	for child in t.children {
		ch, ok := scene_ref_resolve_transform(sc, child, tH)
		if !ok do continue
		_sprite_sort_visit(ch, sc, view, keys, seq, chain, level)
	}
}
