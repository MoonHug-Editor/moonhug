package animation_tests

// Blend1D on the Animation component (docs/AnimationComponent.md): the authored
// entry tree, the 1D weight rule, and the shared phase that keeps children of
// different lengths in step.

import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import common "moonhug:tests/common"

// A layer holding one blend with `kids` clips placed at 0, 1, 2... on the axis.
@(private = "file")
_blend_layer :: proc(a: ^anim.Animation, kids: []engine.Asset_GUID, value: f32) -> (blend_id: i32) {
	entries := make([dynamic]anim.Anim_Entry)
	append(&entries, anim.Anim_Entry{
		id      = 1,
		name    = strings.clone("Locomotion"),
		variant = anim.Blend1D_Entry{value = value},
	})
	for g, i in kids {
		append(&entries, anim.Anim_Entry{
			id      = i32(i) + 2,
			parent  = 1,
			pos     = {f32(i), 0},
			variant = anim.Clip_Entry{clip = g},
		})
	}
	a.layers = make([dynamic]anim.Animation_Layer)
	append(&a.layers, anim.Animation_Layer{entries = entries})
	return 1
}

// The 1D rule end to end: two clips bracketing the value share the weight, and
// the pose that comes out is the blend of both. Asserting on the TRANSFORM
// rather than on input weights is what makes this non-vacuous — it goes through
// the mixer, the pose buffer and the default-pose rule.
@(test)
test_blend1d_interpolates_between_neighbours :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run := _clip_guid(40), _clip_guid(41)
	anim.animation_clip_cache[walk] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[run] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)

	owner := engine.transform_new("Rig")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	id := _blend_layer(a, {walk, run}, 0.5)
	anim.animation_play_entry(a, id)
	anim.animation_tick(0.016)

	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 15) < 0.01,
		"halfway between the two clips, got %v", ot.position.x)

	// Ends clamp rather than falling off toward the default pose.
	anim.animation_blend_set(a, id, 0)
	anim.animation_tick(0.016)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 10) < 0.01, "at 0 the first clip owns it, got %v", ot.position.x)

	anim.animation_blend_set(a, id, 5)
	anim.animation_tick(0.016)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 20) < 0.01, "past the end clamps to the last clip, got %v", ot.position.x)
}

// Children of different lengths share ONE normalized phase, advanced at the
// blended cycle length. Both clips ramp 0 -> 1 over their own length, so if they
// are sampled at the same FRACTION the blend reads exactly that fraction
// whatever the weights are — and if each ran on its own absolute clock the
// shorter one would be further along and drag the result up.
//
// walk is 1.0s, run is 0.5s, value 0.5, so the cycle is 0.75s. After 0.15s the
// phase is 0.2. Per-clip clocks would give 0.5*0.15 + 0.5*0.30 = 0.225.
@(test)
test_blend1d_children_share_one_phase :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run := _clip_guid(42), _clip_guid(43)
	anim.animation_clip_cache[walk] = _ramp_clip(.Position, {0, 0, 0, 0}, {1, 0, 0, 0}, 1.0, .Loop)
	anim.animation_clip_cache[run] = _ramp_clip(.Position, {0, 0, 0, 0}, {1, 0, 0, 0}, 0.5, .Loop)

	owner := engine.transform_new("Rig")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	id := _blend_layer(a, {walk, run}, 0.5)
	anim.animation_play_entry(a, id)
	anim.animation_tick(0.15)

	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 0.2) < 0.005,
		"one shared phase at the blended rate puts both children at 0.2, got %v (0.225 means per-clip clocks)",
		ot.position.x)
}

// A state is addressed by id, and a name resolves to one. Ids are minted so that
// deleting a sibling cannot repoint a play call at something else.
@(test)
test_entry_ids_are_stable_and_named :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run := _clip_guid(44), _clip_guid(45)
	anim.animation_clip_cache[walk] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[run] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)

	owner := engine.transform_new("Rig")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	_ = _blend_layer(a, {walk, run}, 0)
	// A second top-level state beside the blend.
	append(&a.layers[0].entries, anim.Anim_Entry{
		id      = anim.animation_entry_next_id(a),
		name    = strings.clone("Idle"),
		variant = anim.Clip_Entry{clip = walk},
	})

	blend_id, blend_ok := anim.animation_find(a, "Locomotion")
	idle_id, idle_ok := anim.animation_find(a, "Idle")
	testing.expect(t, blend_ok && idle_ok, "both states resolve by name")
	testing.expect(t, blend_id != idle_id, "ids are distinct")

	// Next id is taken over every entry, blend children included, so it can
	// never collide with one already in use.
	testing.expect_value(t, anim.animation_entry_next_id(a), idle_id + 1)

	anim.animation_play_entry(a, idle_id)
	anim.animation_tick(0.016)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 10) < 0.01,
		"playing a clip entry by id poses its clip, got %v", ot.position.x)
}

// Playing a blend replaces a clip state on the same layer and vice versa: one
// layer, one state at a time, whatever kind it is.
@(test)
test_blend_and_clip_states_replace_each_other :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run := _clip_guid(46), _clip_guid(47)
	anim.animation_clip_cache[walk] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[run] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)

	owner := engine.transform_new("Rig")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	blend := _blend_layer(a, {walk, run}, 1)
	anim.animation_play_entry(a, blend)
	anim.animation_tick(0.016)
	testing.expect_value(t, len(a.rt_layers), 1)
	testing.expect_value(t, len(a.rt_layers[0].states), 1)

	// A guid play on the same layer cuts the blend out, taking its children's
	// nodes with it.
	anim.animation_play_clip(a, walk, 0)
	anim.animation_tick(0.016)
	testing.expect_value(t, len(a.rt_layers[0].states), 1)
	testing.expect(t, !a.rt_layers[0].states[0].is_blend, "the surviving state is the clip")

	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expectf(t, abs(ot.position.x - 10) < 0.01, "the clip owns the pose, got %v", ot.position.x)
}

// The entry tree survives a save and load. Unions are the risky part: a variant
// without a registered guid marshals as null and the tree comes back as a list
// of empty entries, which looks exactly like "the author never added anything".
@(test)
test_entry_tree_round_trips :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run := _clip_guid(48), _clip_guid(49)
	anim.animation_clip_cache[walk] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[run] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, ptr := engine.transform_add_comp(root, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	_ = _blend_layer(a, {walk, run}, 0.25)

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "serialize")
	if !ok do return
	defer delete(bytes)

	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "reload")
	if reloaded == nil do return
	tc.scene = reloaded

	_, back := engine.transform_get_comp(engine.Transform_Handle(reloaded.root.handle), anim.Animation)
	testing.expect(t, back != nil, "the component is back")
	if back == nil do return
	testing.expect_value(t, len(back.layers), 1)
	if len(back.layers) != 1 do return
	testing.expect_value(t, len(back.layers[0].entries), 3)
	if len(back.layers[0].entries) != 3 do return

	blend := back.layers[0].entries[0]
	testing.expect_value(t, blend.name, "Locomotion")
	b, is_blend := blend.variant.(anim.Blend1D_Entry)
	testing.expect(t, is_blend, "the first entry is still a blend, not a null variant")
	if is_blend do testing.expectf(t, abs(b.value - 0.25) < 0.0001, "blend value survives, got %v", b.value)

	kid := back.layers[0].entries[2]
	testing.expect_value(t, kid.parent, blend.id)
	testing.expectf(t, abs(kid.pos.x - 1) < 0.0001, "the second child keeps its axis position, got %v", kid.pos.x)
	c, is_clip := kid.variant.(anim.Clip_Entry)
	testing.expect(t, is_clip, "children are still clip entries")
	if is_clip do testing.expect_value(t, c.clip, run)
}

// The shipped sample scene is hand-generated JSON, and its entry tree carries
// hand-written union tags. Loading it here catches a wrong guid or a renamed
// field at test time rather than when someone opens the scene and finds every
// state turned into an empty clip.
@(test)
test_animation_demo_scene_loads :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	// The test asset DB does not scan the samples folder, so the blend's clips
	// would never load and the posing assertion below would pass on a blend
	// that poses nothing.
	CHAR :: "plugins/animation/samples/animation_sample/assets/character/"
	_load_sample_clip(CHAR + "Character3D_walking.anim")
	_load_sample_clip(CHAR + "Character3D_runing.anim")
	_load_sample_clip(CHAR + "Character3D_idle_01.anim")

	PATH :: "plugins/animation/samples/animation_sample/assets/animation_demo.scene"
	s := engine.scene_load_single_path(PATH)
	testing.expect(t, s != nil, "the sample scene parses and loads")
	if s == nil do return
	tc.scene = s

	root := engine.Transform_Handle(s.root.handle)
	char := _find_child_named(tc, root, "Character3D")
	testing.expect(t, char != {}, "the character is in the scene")
	if char == {} do return
	_, a := engine.transform_get_comp(char, anim.Animation)
	testing.expect(t, a != nil, "the character carries an Animation")
	if a == nil do return

	testing.expect_value(t, len(a.layers), 1)
	if len(a.layers) != 1 do return

	blend_id, blend_ok := anim.animation_find(a, "Locomotion")
	testing.expect(t, blend_ok, "the walk/run blend resolves by name")
	if !blend_ok do return
	e := anim.animation_entry(a, blend_id)
	testing.expect(t, e != nil, "the blend entry is there")
	if e == nil do return
	_, is_blend := e.variant.(anim.Blend1D_Entry)
	testing.expect(t, is_blend, "it survived as a blend, not the zero variant")

	kids := 0
	for &entry in a.layers[0].entries {
		if entry.parent == blend_id do kids += 1
	}
	testing.expect_value(t, kids, 2)

	_, idle_ok := anim.animation_find(a, "Idle")
	_, jump_ok := anim.animation_find(a, "Jump")
	_, death_ok := anim.animation_find(a, "Death")
	testing.expect(t, idle_ok && jump_ok && death_ok, "the single-clip states resolve too")

	// End to end: playing the blend poses a joint several levels down the name
	// path, which is the thing a bad clip target or a broken entry would break.
	a.enabled = true
	a.started = true
	barriga := _find_child_named(tc, char, "BARRIGA")
	testing.expect(t, barriga != {}, "the armature is intact")
	if barriga == {} do return
	before := engine.pool_get(&tc.world.transforms, engine.Handle(barriga)).rotation

	anim.animation_play_entry(a, blend_id)
	anim.animation_tick(0.2)
	after := engine.pool_get(&tc.world.transforms, engine.Handle(barriga)).rotation
	testing.expectf(t, before != after, "the blend poses the rig, rotation stayed %v", after)
}

// Depth-first by name, since a scene has no by-name lookup.
@(private = "file")
_find_child_named :: proc(tc: ^common.TestCtx, h: engine.Transform_Handle, name: string) -> engine.Transform_Handle {
	t := engine.pool_get(&tc.world.transforms, engine.Handle(h))
	if t == nil do return {}
	if t.name == name do return h
	for ch in t.children {
		if got := _find_child_named(tc, engine.Transform_Handle(ch.handle), name); got != {} do return got
	}
	return {}
}

// One builder for every reader of the tree. The Playable Graph window and the
// scrub preview used to build their own copies of this shape, and the preview's
// never learned about blends — so what the window showed while scrubbing was not
// what the component played. Now they and the driver share animation_entry_build,
// and this pins the shape they agree on.
@(test)
test_authored_graph_matches_the_tree :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()

	walk, run, idle := _clip_guid(50), _clip_guid(51), _clip_guid(52)
	anim.animation_clip_cache[walk] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[run] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)
	anim.animation_clip_cache[idle] = _const_clip(.Position, {0, 0, 0, 0}, 1, .Loop)

	owner := engine.transform_new("Rig")
	_, ptr := engine.transform_add_comp(owner, .Animation)
	a := cast(^anim.Animation)ptr
	a.enabled = true
	a.speed = 1
	a.started = true

	_ = _blend_layer(a, {walk, run}, 0)
	append(&a.layers[0].entries, anim.Anim_Entry{
		id      = anim.animation_entry_next_id(a),
		name    = strings.clone("Idle"),
		variant = anim.Clip_Entry{clip = idle},
	})
	// The default clip names a clip an entry already holds: it must not become
	// a second leaf.
	a.clip = idle

	g: anim.Playable_Graph
	leaves := make([dynamic]anim.Authored_Leaf)
	defer delete(leaves)
	anim.animation_graph_build_authored(a, &g, owner, 1, &leaves)
	defer anim.playable_graph_destroy(&g)

	// root + layer mixer + blend mixer + three clips.
	alive := 0
	for &n in g.nodes do if n.alive do alive += 1
	testing.expect_value(t, alive, 6)
	testing.expect_value(t, len(leaves), 3)

	blend_top: anim.Playable_Handle
	for l in leaves {
		if l.clip == idle {
			testing.expect(t, l.under == l.layer && l.top == l.node, "a top-level clip hangs from the layer mixer")
			continue
		}
		testing.expect(t, l.under != l.layer && l.under == l.top, "a blend child hangs from its blend's mixer")
		if blend_top == {} do blend_top = l.top
		testing.expect(t, l.top == blend_top, "both children share one blend mixer")
	}

	// The driver builds the same blend through the same primitive.
	bid, _ := anim.animation_find(a, "Locomotion")
	anim.animation_play_entry(a, bid)
	testing.expect_value(t, len(a.rt_layers[0].states), 1)
	st := &a.rt_layers[0].states[0]
	testing.expect(t, st.is_blend, "a blend entry plays as a blend state")
	testing.expect_value(t, len(st.kids), 2)
	testing.expect(t, st.kids[0].pos <= st.kids[1].pos, "children come out sorted by position")
}
