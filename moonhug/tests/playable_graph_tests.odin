package tests

// PlayableGraph evaluation (docs/PlayableGraph.md): pose blending against the
// bind-time default pose, mixer and layer-mixer semantics, script collection —
// and the Animation component milestone on top: layers, cross-fade,
// interruption, queued play.

import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "../engine"
import common "common"

// A constant single-key clip: owner `prop` = `value` for its whole length.
_const_clip :: proc(path: engine.Animation_Path, value: [4]f32, length: f32 = 1, wrap: engine.Animation_Wrap = .Loop, target := "") -> engine.AnimationClip {
	clip := engine.AnimationClip{length = length, wrap = wrap}
	clip.channels = make([dynamic]engine.Animation_Channel)
	ch := engine.Animation_Channel{path = path}
	if target != "" do ch.target = strings.clone(target)
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, value)
	append(&clip.channels, ch)
	return clip
}

_clip_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: uuid.Identifier
	id[15] = n
	id[0] = 0xAA
	return engine.Asset_GUID(id)
}

@(test)
test_playable_mixer_blend :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	a_guid, b_guid := _clip_guid(1), _clip_guid(2)
	engine.animation_clip_cache[a_guid] = _const_clip(.Position, {0, 0, 0, 0})
	engine.animation_clip_cache[b_guid] = _const_clip(.Position, {4, 0, 0, 0})

	owner := engine.transform_new("Rig")

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)

	mixer := engine.playable_add(&g, engine.Mixer_Playable{})
	g.root = mixer
	engine.playable_connect(&g, mixer, engine.playable_add(&g, engine.Clip_Playable{clip = a_guid}), 0.5)
	engine.playable_connect(&g, mixer, engine.playable_add(&g, engine.Clip_Playable{clip = b_guid}), 0.5)

	pose := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)

	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 2) < 0.001, "50/50 mix of x=0 and x=4 should land at 2")
}

@(test)
test_playable_partial_weight_blends_default :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	guid := _clip_guid(3)
	engine.animation_clip_cache[guid] = _const_clip(.Position, {10, 0, 0, 0})

	owner := engine.transform_new("Rig")
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	ot.position = {2, 0, 0} // the default pose captured at bind time

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)

	mixer := engine.playable_add(&g, engine.Mixer_Playable{})
	g.root = mixer
	engine.playable_connect(&g, mixer, engine.playable_add(&g, engine.Clip_Playable{clip = guid}), 0.3)

	pose := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)

	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	// Default pose rule: 0.3 * 10 + 0.7 * 2 = 4.4 — blended against the
	// BIND-TIME value, not toward zero and not feeding back per frame.
	testing.expect(t, abs(ot.position.x - 4.4) < 0.001, "weight 0.3 should blend clip against the bind-time default")

	// Purity: evaluating again at the same state gives the same result — the
	// default did not drift toward the written value.
	pose2 := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose2)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 4.4) < 0.001, "re-evaluating must not drift (blends against default, not live)")
}

@(test)
test_playable_layer_override :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	lo_guid, hi_guid := _clip_guid(4), _clip_guid(5)
	engine.animation_clip_cache[lo_guid] = _const_clip(.Position, {1, 0, 0, 0})
	engine.animation_clip_cache[hi_guid] = _const_clip(.Position, {9, 0, 0, 0})

	owner := engine.transform_new("Rig")

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)

	root := engine.playable_add(&g, engine.Layer_Mixer_Playable{})
	g.root = root
	l0 := engine.playable_add(&g, engine.Mixer_Playable{})
	l1 := engine.playable_add(&g, engine.Mixer_Playable{})
	engine.playable_connect(&g, root, l0, 1)
	engine.playable_connect(&g, root, l1, 1)
	engine.playable_connect(&g, l0, engine.playable_add(&g, engine.Clip_Playable{clip = lo_guid}), 1)
	engine.playable_connect(&g, l1, engine.playable_add(&g, engine.Clip_Playable{clip = hi_guid}), 1)

	pose := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 9) < 0.001, "the higher layer at full weight should override the lower")

	// Half-weight upper layer blends over the lower layer's result.
	engine.playable_set_input_weight(&g, root, l1, 0.5)
	pose = engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 5) < 0.001, "a half-weight layer should blend over the lower layer (1 -> 9 at 0.5 = 5)")
}

@(test)
test_playable_rotation_blend :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	a_guid, b_guid := _clip_guid(6), _clip_guid(7)
	engine.animation_clip_cache[a_guid] = _const_clip(.Rotation, {0, 0, 0, 1})            // identity
	engine.animation_clip_cache[b_guid] = _const_clip(.Rotation, {0, 0, 0.70711, 0.70711}) // 90 deg about z

	owner := engine.transform_new("Rig")

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)

	mixer := engine.playable_add(&g, engine.Mixer_Playable{})
	g.root = mixer
	engine.playable_connect(&g, mixer, engine.playable_add(&g, engine.Clip_Playable{clip = a_guid}), 0.5)
	engine.playable_connect(&g, mixer, engine.playable_add(&g, engine.Clip_Playable{clip = b_guid}), 0.5)

	pose := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	// nlerp of identity and 90 deg = 45 deg about z: {0, 0, 0.38268, 0.92388}
	testing.expect(t, abs(ot.rotation.z - 0.38268) < 0.01 && abs(ot.rotation.w - 0.92388) < 0.01,
		"50/50 rotation mix should land at 45 degrees")
}

@(test)
test_playable_script_collection :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	owner := engine.transform_new("Rig")

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)

	Fired :: struct {
		count:  int,
		time:   f32,
		weight: f32,
	}
	fired: Fired

	mixer := engine.playable_add(&g, engine.Mixer_Playable{})
	g.root = mixer
	script := engine.playable_add(&g, engine.Script_Playable{
		user_data = &fired,
		process = proc(data: rawptr, time: f32, weight: f32) {
			f := cast(^Fired)data
			f.count += 1
			f.time = time
			f.weight = weight
		},
	})
	engine.playable_connect(&g, mixer, script, 0.7)
	if node := engine.playable_node(&g, script); node != nil do node.time = 1.5

	scripts := make([dynamic]engine.Script_Invocation, context.temp_allocator)
	pose := engine.playable_graph_evaluate(&g, &b, &scripts)
	engine.animation_pose_apply(&b, pose)
	testing.expect(t, fired.count == 0, "callbacks must not fire during evaluation")
	engine.playable_scripts_fire(scripts[:])
	testing.expect(t, fired.count == 1, "collected script should fire once")
	testing.expect(t, abs(fired.time - 1.5) < 0.001 && abs(fired.weight - 0.7) < 0.001,
		"script should receive its local time and path weight")
}

// --- Animation component: the milestone ---------------------------------------------

@(private = "file")
_milestone_setup :: proc(tc: ^common.TestCtx) -> (owner: engine.Transform_Handle, a: ^engine.Animation, a_guid, b_guid, c_guid: engine.Asset_GUID) {
	a_guid, b_guid, c_guid = _clip_guid(10), _clip_guid(11), _clip_guid(12)
	engine.animation_clip_cache[a_guid] = _const_clip(.Position, {0, 0, 0, 0}, 1, .Once)
	engine.animation_clip_cache[b_guid] = _const_clip(.Position, {10, 0, 0, 0}, 1, .Loop)
	engine.animation_clip_cache[c_guid] = _const_clip(.Position, {20, 0, 0, 0}, 1, .Loop)

	owner = engine.transform_new("Rig")
	_, a_ptr := engine.transform_add_comp(owner, .Animation)
	a = cast(^engine.Animation)a_ptr
	a.enabled = true
	a.speed = 1
	a.play_automatically = false
	a.started = true
	return
}

@(test)
test_animation_cross_fade :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	owner, a, a_guid, b_guid, _ := _milestone_setup(tc)

	engine.animation_play_clip(a, a_guid)
	engine.animation_tick(0.1)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x) < 0.001, "clip A alone should hold x=0")

	engine.animation_cross_fade(a, b_guid, 1.0)
	engine.animation_tick(0.5)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 5) < 0.01, "halfway through the fade x should be 5 (weights 0.5/0.5)")

	engine.animation_tick(0.6)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 10) < 0.01, "after the fade x should be 10")
	testing.expect(t, len(a.rt_layers[0].states) == 1, "the faded-out state should be removed")
	testing.expect(t, a.playing, "loop clip keeps playing")
}

@(test)
test_animation_cross_fade_interrupt :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	owner, a, a_guid, b_guid, c_guid := _milestone_setup(tc)

	engine.animation_play_clip(a, a_guid)
	engine.animation_tick(0.1)
	engine.animation_cross_fade(a, b_guid, 1.0)
	engine.animation_tick(0.5) // mid-fade: A 0.5, B 0.5, x = 5

	// Interrupt: everything fades from its CURRENT weight, so the pose is
	// continuous — one tiny tick later x must still be ~5, no snap.
	engine.animation_cross_fade(a, c_guid, 1.0)
	engine.animation_tick(0.01)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 5) < 0.3, "interruption must not snap the pose")

	// Half through the second fade: A 0.25, B 0.25, C 0.5 -> x = 12.5.
	engine.animation_tick(0.49)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 12.5) < 0.2, "interrupted fade should blend all three continuously")

	// Fade completes: only C remains.
	engine.animation_tick(0.6)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 20) < 0.01, "after the interrupted fade x should be C's value")
	testing.expect(t, len(a.rt_layers[0].states) == 1, "both faded-out states should be removed")
}

@(test)
test_animation_queued :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	owner, a, a_guid, b_guid, _ := _milestone_setup(tc)

	engine.animation_play_clip(a, a_guid) // Once, length 1
	engine.animation_cross_fade_queued(a, b_guid, 0.5)
	engine.animation_tick(0.5)
	testing.expect(t, len(a.rt_layers[0].states) == 1, "queue must not fire while the clip plays")

	engine.animation_tick(0.6) // A passes its end -> queue fires
	testing.expect(t, len(a.rt_layers[0].states) == 2, "queue should start the cross-fade when the clip finishes")

	engine.animation_tick(0.25) // half the 0.5 fade: A 0.5 (holding x=0), B 0.5 (x=10)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 5) < 0.01, "queued fade should blend from the held end pose")

	engine.animation_tick(0.3)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 10) < 0.01, "queued clip should own the pose after its fade")
	testing.expect(t, a.playing, "queued loop clip keeps playing")
}

@(test)
test_animation_layers_stack :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	owner, a, _, b_guid, c_guid := _milestone_setup(tc)
	// A scale clip on layer 0 plus a position clip on layer 1: both apply.
	s_guid := _clip_guid(13)
	engine.animation_clip_cache[s_guid] = _const_clip(.Scale, {3, 3, 3, 0}, 1, .Loop)

	engine.animation_play_clip(a, s_guid, 0)
	engine.animation_play_clip(a, b_guid, 1)
	engine.animation_tick(0.1)
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.scale.x - 3) < 0.001, "layer 0 scale clip should apply")
	testing.expect(t, abs(ot.position.x - 10) < 0.001, "layer 1 position clip should apply")

	// Authored layers: list C on layer 1, then cross-fade WITHOUT a layer
	// argument — the component resolves the layer from the authored data.
	// Layer 0 must stay untouched.
	append(&a.layers, engine.Animation_Layer{}, engine.Animation_Layer{})
	a.layers[1].clips = make([dynamic]engine.Asset_GUID)
	append(&a.layers[1].clips, c_guid)
	engine.animation_cross_fade(a, c_guid, 1.0)
	engine.animation_tick(0.5)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.scale.x - 3) < 0.001, "layer 0 should be untouched by a layer 1 fade")
	testing.expect(t, abs(ot.position.x - 15) < 0.01, "layer 1 mid-fade should blend 10 -> 20")
	testing.expect(t, len(a.rt_layers) == 2, "two layers exist")
}

// The editor scrub preview's per-frame cycle (view_animation.odin): refresh
// defaults from the live transforms, evaluate at the scrub time, apply, then
// write the defaults back. The world returns to authored values every frame,
// and an authored edit made between scrubs becomes the new restore target.
@(test)
test_playable_scrub_preview_cycle :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	// Two-key clip: x moves 0 -> 8 over 1s, so the scrub time is observable.
	guid := _clip_guid(40)
	clip := engine.AnimationClip{length = 1, wrap = .Once}
	clip.channels = make([dynamic]engine.Animation_Channel)
	ch := engine.Animation_Channel{path = .Position}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, [4]f32{0, 0, 0, 0})
	append(&ch.times, 1)
	append(&ch.values, [4]f32{8, 0, 0, 0})
	append(&clip.channels, ch)
	engine.animation_clip_cache[guid] = clip

	owner := engine.transform_new("Rig")
	ot := engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	ot.position = {1, 2, 3} // authored pose

	g: engine.Playable_Graph
	engine.playable_graph_init(&g)
	defer engine.playable_graph_destroy(&g)
	b: engine.Animation_Binding
	engine.animation_binding_init(&b, owner)
	defer engine.animation_binding_destroy(&b)
	g.root = engine.playable_add(&g, engine.Clip_Playable{clip = guid})

	// Frame 1: scrub to t=0.5 — the pose renders, the restore puts the
	// authored values back.
	engine.animation_binding_refresh_defaults(&b)
	if n := engine.playable_node(&g, g.root); n != nil do n.time = 0.5
	pose := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 4) < 0.001, "scrub at t=0.5 should pose x at 4")
	engine.animation_binding_write_defaults(&b)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, ot.position == [3]f32{1, 2, 3}, "restore should return the authored pose")

	// Frame 2: the user edits the authored value between scrubs — refresh
	// captures it, so the next restore lands on the EDITED value, not the
	// value captured when the preview started.
	ot.position = {5, 2, 3}
	engine.animation_binding_refresh_defaults(&b)
	if n := engine.playable_node(&g, g.root); n != nil do n.time = 0.25
	pose2 := engine.playable_graph_evaluate(&g, &b)
	engine.animation_pose_apply(&b, pose2)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, abs(ot.position.x - 2) < 0.001, "scrub at t=0.25 should pose x at 2")
	engine.animation_binding_write_defaults(&b)
	ot = engine.pool_get(&tc.world.transforms, engine.Handle(owner))
	testing.expect(t, ot.position == [3]f32{5, 2, 3}, "restore should return the EDITED authored pose")
}

// animation_clip_preview replaces the cached clip with a deep copy — the
// editor's live preview of unsaved keyframe edits. The cache copy must be
// independent of the source (the document keeps mutating after the sync).
@(test)
test_animation_clip_preview_replaces_cache :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	engine.animation_clip_cache_init()
	defer engine.animation_clip_cache_shutdown()

	guid := _clip_guid(41)
	engine.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	doc := _const_clip(.Position, {7, 0, 0, 0}, length = 2)
	defer engine._animation_clip_destroy(&doc)
	engine.animation_clip_preview(guid, doc)

	cached, ok := engine.animation_clip_load(guid)
	testing.expect(t, ok, "cache entry survives the preview swap")
	testing.expect(t, abs(cached.length - 2) < 0.001, "preview replaced the cached length")
	testing.expect(t, abs(cached.channels[0].values[0].x - 7) < 0.001, "preview replaced the cached values")

	// Independence: mutating the source must not reach the cache.
	doc.channels[0].values[0].x = 9
	cached2, _ := engine.animation_clip_load(guid)
	testing.expect(t, abs(cached2.channels[0].values[0].x - 7) < 0.001, "cache copy is deep")
}
