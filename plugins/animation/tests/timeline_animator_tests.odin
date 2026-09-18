package animation_tests

// TimelineAnimator (docs/TimelineAnimator.md): the component's graph skeleton —
// one output per object its timelines' tracks drive, a layer mixer at each
// output's root, one mixer per layer under it.
//
// A track's own `target` is the ONLY binding, under an animator or not. The
// animator reads those targets to size its outputs, and changes only where a
// track's subtree hangs — never what it drives.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import inspector "moonhug:editor/inspector"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

@(test)
test_timeline_animator_graph_skeleton :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	anim.animation_track_init()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	guid := _clip_guid(11)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	face := engine.transform_new("Face", root)

	b_owned, _ := engine.transform_add_comp(body, .Animation)
	f_owned, _ := engine.transform_add_comp(face, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	// The outputs come from what the states' tracks drive: one timeline on
	// Body, one on Face, on either layer.
	base := anim.Animator_Layer{name = strings.clone("Base")}
	base.states = make([dynamic]anim.Timeline_State)
	append(&base.states, _mk_state("A", _mk_local_timeline(root, b_owned.handle, guid)))
	upper := anim.Animator_Layer{name = strings.clone("Upper"), weight = 0.5}
	upper.states = make([dynamic]anim.Timeline_State)
	append(&upper.states, _mk_state("B", _mk_local_timeline(root, f_owned.handle, guid)))
	append(&ta.layers, base)
	append(&ta.layers, upper)

	anim.timeline_animator_tick(0)

	testing.expect_value(t, len(ta.graph.outputs), 2)
	testing.expect_value(t, anim.timeline_animator_output_index(ta, body), 0)
	testing.expect_value(t, anim.timeline_animator_output_index(ta, face), 1)
	testing.expect_value(t, anim.timeline_animator_output_index(ta, root), -1)

	for oi in 0 ..< 2 {
		o := anim.graph_output(&ta.graph, oi)
		testing.expect(t, o != nil, "every driven object has an output")
		n := anim.playable_node(&ta.graph, o.root)
		testing.expect(t, n != nil, "the output root is a live node")
		// One mixer per layer, in layer order — input order IS override order.
		testing.expect_value(t, len(n.inputs), 2)
		testing.expect_value(t, n.inputs[0].node, anim.timeline_animator_layer_mixer(ta, 0, oi))
		testing.expect_value(t, n.inputs[1].node, anim.timeline_animator_layer_mixer(ta, 1, oi))
		// Layer weight is zero-neutral: unset is full strength, not silent.
		testing.expect(t, abs(n.inputs[0].weight - 1) < 0.001, "unset layer weight reads as 1")
		testing.expect(t, abs(n.inputs[1].weight - 0.5) < 0.001, "an authored layer weight is used")
	}
}

// A track with no target drives its director's own object — the default a
// self-contained timeline relies on — and the animator builds that output like
// any other. Two states, one on Body and one unset, give two outputs.
@(test)
test_unset_track_target_falls_back_to_director :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_track_init()
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	guid := _clip_guid(12)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	bound := _mk_local_timeline(root, b_owned.handle, guid)
	loose := _mk_local_timeline(root, {}, guid) // no target, no Animation on the director
	append(&layer.states, _mk_state("Bound", bound))
	append(&layer.states, _mk_state("Loose", loose))
	append(&ta.layers, layer)

	anim.timeline_animator_tick(0)

	testing.expect_value(t, len(ta.graph.outputs), 2)
	testing.expect(t, anim.timeline_animator_output_index(ta, body) >= 0, "a targeted track poses its target")
	testing.expect(t, anim.timeline_animator_output_index(ta, loose) >= 0, "an untargeted track poses its own director")
}

@(test)
test_timeline_animator_idle_leaves_targets_alone :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	// A state exists, so Body has an output — but nothing plays it.
	anim.animation_track_init()
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("Idle", _mk_local_timeline(root, b_owned.handle, {})))
	append(&ta.layers, layer)

	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {3, 0, 0}

	// No state has weight, so the graph would evaluate to an empty pose.
	// Applying that would write bind-time defaults over whatever else poses
	// the object, so an idle animator must not apply at all.
	anim.timeline_animator_tick(0)
	anim.timeline_animator_tick(0)

	testing.expect(t, len(ta.graph.outputs) == 1, "the state's target has an output")
	testing.expect(t, abs(bt.position.x - 3) < 0.001,
		"an animator playing nothing does not touch its targets")
}

// A timeline living in the scene: a director with one animation track driving
// the Animation `target`, playing `clip` across its whole length. The track's
// own target is the only binding there is — under an animator too.
@(private = "file")
_mk_local_timeline :: proc(parent: engine.Transform_Handle, target: engine.Handle, clip: engine.Asset_GUID, length: f32 = 1) -> engine.Transform_Handle {
	tl := engine.transform_new("Timeline", parent)
	_, draw := engine.transform_add_comp(tl, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw
	d.enabled = true
	d.duration = length
	d.wrap = .Loop

	track := engine.transform_new("animation", tl)
	engine.transform_get_or_add_comp(track, seq.TimelineTrack)
	_, traw := engine.transform_add_comp(track, .TrackAnimation)
	(cast(^anim.TrackAnimation)traw).target = {handle = target}

	cn := engine.transform_new("clip", track)
	_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
	cc.start = 0
	cc.duration = length
	_, ca := engine.transform_add_comp(cn, .ClipAnimation)
	(cast(^anim.ClipAnimation)ca).clip = clip
	return tl
}

@(private = "file")
// The state names the DIRECTOR on `tl`, not `tl` itself — the animator takes
// its owner as the timeline root.
_mk_state :: proc(name: string, tl: engine.Transform_Handle, fade: f32 = 0) -> anim.Timeline_State {
	owned, _ := engine.transform_get_comp_key(tl, .PlayableDirector)
	return {
		name     = strings.clone(name),
		timeline = {local_id = owned.local_id, handle = owned.handle},
		fade     = fade,
		wrap     = .Loop,
	}
}

// A state may point at a timeline that already lives in the scene: guid zero,
// local_id set. The animator adopts it where it stands and must not destroy it
// on rebuild — it never created it.
@(test)
test_state_adopts_local_timeline :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_track_init()

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	engine.transform_add_comp(body, .Animation)

	tl := engine.transform_new("Timeline", root)
	d_owned, draw := engine.transform_add_comp(tl, .PlayableDirector)
	(cast(^seq.PlayableDirector)draw).enabled = true

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, anim.Timeline_State{
		name     = strings.clone("Idle"),
		// guid zero: a local reference, naming the director in this scene
		timeline = {local_id = d_owned.local_id, handle = d_owned.handle},
	})
	append(&ta.layers, layer)

	anim.timeline_animator_tick(0)
	testing.expect(t, anim.animation_director_is_adopted(tl),
		"a local timeline is adopted where it stands")

	// Rebuilding drops the adoption and leaves the object alone.
	anim.timeline_animator_rebuild(ta)
	testing.expect(t, !anim.animation_director_is_adopted(tl), "rebuild releases the adoption")
	testing.expect(t, engine.pool_valid(&tc.world.transforms, engine.Handle(tl)),
		"a timeline the animator did not create survives its rebuild")
}

// Playing a state routes its timeline's tracks to the keys the animator binds,
// and the animator's flush is what poses the object. An adopted track never
// applies a pose of its own.
//
// This is also THE fallback test: the timeline is self-contained — its track
// names Body directly, the animator binds nothing — and it plays under the
// animator with zero setup. Before, an adopted track's own target was ignored
// and this exact timeline would have been inert.
@(test)
test_state_play_poses_track_target :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	guid := _clip_guid(41)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {7, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, b_raw := engine.transform_add_comp(body, .Animation)
	driven := cast(^anim.Animation)b_raw
	driven.enabled = true

	tl := _mk_local_timeline(root, b_owned.handle, guid)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("Idle", tl))
	append(&ta.layers, layer)

	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))

	// States exist but none plays: the object is left alone and keeps itself.
	anim.timeline_animator_tick(0)
	testing.expect(t, abs(bt.position.x) < 0.001, "a silent animator poses nothing")
	testing.expect(t, !driven.timeline_driven, "a silent animator claims nothing")

	id, found := anim.animator_find(ta, "Idle")
	testing.expect(t, found, "the state resolves by name")
	anim.animator_play(ta, id, 0)
	anim.timeline_animator_tick(0.1)

	testing.expect(t, abs(bt.position.x - 7) < 0.001,
		"playing a state poses the track's target through the animator")
	testing.expect(t, driven.timeline_driven, "playing claims the bound component")
}

// A cross-fade moves one weight per state, and the pose lands between the two
// timelines rather than on either. Interrupting mid-fade retargets from the
// CURRENT weights, so nothing snaps.
@(test)
test_state_cross_fade_blends :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	lo, hi := _clip_guid(42), _clip_guid(43)
	anim.animation_clip_cache[lo] = _const_clip(.Position, {0, 0, 0, 0})
	anim.animation_clip_cache[hi] = _const_clip(.Position, {10, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	tl_a := _mk_local_timeline(root, b_owned.handle, lo)
	tl_b := _mk_local_timeline(root, b_owned.handle, hi)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("A", tl_a))
	append(&layer.states, _mk_state("B", tl_b, fade = 1))
	append(&ta.layers, layer)

	a_id, _ := anim.animator_find(ta, "A")
	b_id, _ := anim.animator_find(ta, "B")

	anim.animator_play(ta, a_id, 0) // 0 is a hard cut
	anim.timeline_animator_tick(0)
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	testing.expect(t, abs(bt.position.x) < 0.001, "A alone poses 0")

	// The default fade of -1 takes the state's authored duration, 1 second.
	anim.animator_play(ta, b_id)
	anim.timeline_animator_tick(0.25)
	testing.expect(t, abs(bt.position.x - 2.5) < 0.01,
		"a quarter through the fade the pose is a quarter of the way to B")

	anim.timeline_animator_tick(0.25)
	testing.expect(t, abs(bt.position.x - 5) < 0.01, "halfway through the fade")

	// The leading state flips once B passes A.
	anim.timeline_animator_tick(0.3)
	lead, _, _ := anim.animator_state(ta)
	testing.expect_value(t, lead, b_id)

	anim.timeline_animator_tick(1)
	testing.expect(t, abs(bt.position.x - 10) < 0.01, "the fade completes on B")
}

// Interrupting a fade retargets from the CURRENT weights, so the pose stays
// continuous: no snap back to the outgoing state, no jump to the new one.
@(test)
test_state_fade_interrupted_by_third :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	ga, gb, gc := _clip_guid(51), _clip_guid(52), _clip_guid(53)
	anim.animation_clip_cache[ga] = _const_clip(.Position, {0, 0, 0, 0})
	anim.animation_clip_cache[gb] = _const_clip(.Position, {10, 0, 0, 0})
	anim.animation_clip_cache[gc] = _const_clip(.Position, {20, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("A", _mk_local_timeline(root, b_owned.handle, ga)))
	append(&layer.states, _mk_state("B", _mk_local_timeline(root, b_owned.handle, gb)))
	append(&layer.states, _mk_state("C", _mk_local_timeline(root, b_owned.handle, gc)))
	append(&ta.layers, layer)

	a_id, _ := anim.animator_find(ta, "A")
	b_id, _ := anim.animator_find(ta, "B")
	c_id, _ := anim.animator_find(ta, "C")
	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))

	anim.animator_play(ta, a_id, 0)
	anim.timeline_animator_tick(0)

	// Half into A -> B: weights are 0.5/0.5, so the pose sits at 5.
	anim.animator_play(ta, b_id, 1)
	anim.timeline_animator_tick(0.5)
	testing.expect(t, abs(bt.position.x - 5) < 0.01, "halfway through A to B")
	before := bt.position.x

	// Interrupt toward C. The first frame of the new fade barely moves: A and
	// B leave from 0.5 each, C enters from 0, so the pose is still near 5.
	anim.animator_play(ta, c_id, 1)
	anim.timeline_animator_tick(0.001)
	testing.expectf(t, abs(bt.position.x - before) < 0.2,
		"an interrupted fade is continuous, went %v -> %v", before, bt.position.x)

	// And it still arrives at C.
	anim.timeline_animator_tick(1)
	testing.expect(t, abs(bt.position.x - 20) < 0.01, "the interrupted fade lands on C")
}

// A state's own speed scales its playhead, independently of the animator's.
@(test)
test_state_speed_scales_its_playhead :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	guid := _clip_guid(54)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.speed = 2
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	st := _mk_state("Fast", _mk_local_timeline(root, b_owned.handle, guid, 10))
	st.speed = 3
	append(&layer.states, st)
	append(&ta.layers, layer)

	id, _ := anim.animator_find(ta, "Fast")
	anim.animator_play(ta, id, 0)
	anim.timeline_animator_tick(1)

	// animator speed 2 * state speed 3 = 6 seconds of a 10 second timeline.
	_, normalized, _ := anim.animator_state(ta)
	testing.expectf(t, abs(normalized - 0.6) < 0.001,
		"state speed multiplies the animator's, got %v", normalized)
}

// Authoring problems are found when the graph is built, not discovered as a
// character that silently never moves.
@(test)
test_animator_reports_authoring_problems :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	guid := _clip_guid(55)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	// Nested INSIDE body, so the two pose outputs overlap.
	inner := engine.transform_new("Inner", body)

	b_owned, _ := engine.transform_add_comp(body, .Animation)
	i_owned, _ := engine.transform_add_comp(inner, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	// One timeline poses Body, another poses Inner, which sits inside Body.
	append(&layer.states, _mk_state("Outer", _mk_local_timeline(root, b_owned.handle, guid)))
	append(&layer.states, _mk_state("Inner", _mk_local_timeline(root, i_owned.handle, guid)))
	append(&ta.layers, layer)

	anim.timeline_animator_tick(0)
	problems := anim.timeline_animator_problems(ta)

	overlap := 0
	for p in problems {
		if p.kind == .Overlapping_Pose {
			overlap += 1
			testing.expect_value(t, p.object, inner)
		}
	}
	testing.expect(t, overlap == 1, "two pose outputs that overlap are reported, against the inner one")
}

// The shipped sample scene is hand-generated JSON, which is exactly the kind of
// asset that rots silently. Loading it here catches a renamed field or a bad
// local_id at test time instead of when someone opens it.
@(test)
test_timeline_animator_demo_scene_loads :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	// The test asset DB does not scan the samples folder, so the clips the
	// sample's timelines reference would never load and every later assertion
	// would pass on an animator that poses nothing. Seed the cache by hand.
	_load_sample_clip("plugins/animation/samples/timeline_sample/assets/rig_idle.anim")
	_load_sample_clip("plugins/animation/samples/timeline_sample/assets/rig_swing_body.anim")
	_load_sample_clip("plugins/animation/samples/timeline_sample/assets/rig_swing_prop.anim")

	PATH :: "plugins/animation/samples/timeline_sample/assets/timeline_animator_demo.scene"
	s := engine.scene_load_single_path(PATH)
	testing.expect(t, s != nil, "the sample scene parses and loads")
	if s == nil do return
	tc.scene = s

	root := engine.Transform_Handle(s.root.handle)
	_, ta := engine.transform_get_comp(root, anim.TimelineAnimator)
	testing.expect(t, ta != nil, "the root carries a TimelineAnimator")
	if ta == nil do return

	testing.expect_value(t, len(ta.layers), 1)
	testing.expect_value(t, len(ta.layers[0].states), 2)

	anim.timeline_animator_tick(0)
	// The tracks target the Animations on Body (8009) and Sword (8023), so
	// those two objects are what the animator poses.
	body_h, _ := engine.scene_find_selectable_transform_local_id(s, 8009)
	sword_h, _ := engine.scene_find_selectable_transform_local_id(s, 8023)
	testing.expect(t, anim.timeline_animator_output_index(ta, body_h) >= 0, "Body is posed")
	testing.expect(t, anim.timeline_animator_output_index(ta, sword_h) >= 0, "Sword is posed")
	_, i_ok := anim.animator_find(ta, "Idle")
	_, s_ok := anim.animator_find(ta, "Swing")
	testing.expect(t, i_ok && s_ok, "both states resolve by name")
	testing.expect_value(t, len(anim.timeline_animator_problems(ta)), 0)

	// End to end, and specifically the thing a clip player cannot do: ONE
	// state posing two targets. Swing rotates ArmR (several levels down
	// a name path) and the Sword (a different Animation component).
	arm := _find_by_name(tc, root, "ArmR")
	sword := _find_by_name(tc, root, "Sword")
	testing.expect(t, arm != nil && sword != nil, "the rig has an ArmR and a Sword")
	if arm == nil || sword == nil do return

	id, _ := anim.animator_find(ta, "Swing")
	anim.animator_play(ta, id, 0)
	anim.timeline_animator_tick(0.35) // the top of the arc

	testing.expectf(t, abs(arm.rotation.z) > 0.1,
		"Swing rotates the body rig, got %v", arm.rotation.z)
	testing.expectf(t, abs(sword.rotation.z) > 0.1,
		"the same state also poses the prop through its own key, got %v", sword.rotation.z)
}

// Depth-first by name, since a scene has no by-name lookup.
@(private = "file")
_find_by_name :: proc(tc: ^common.TestCtx, h: engine.Transform_Handle, name: string) -> ^engine.Transform {
	t := engine.pool_get(&tc.world.transforms, engine.Handle(h))
	if t == nil do return nil
	if t.name == name do return t
	for ch in t.children {
		if got := _find_by_name(tc, engine.Transform_Handle(ch.handle), name); got != nil do return got
	}
	return nil
}


// Read a .anim and its .meta straight into the clip cache, bypassing the asset
// DB. Only for tests that load shipped sample assets by path.
_load_sample_clip :: proc(path: string) {
	meta_path := strings.concatenate({path, ".meta"}, context.temp_allocator)
	meta_bytes, merr := os.read_entire_file(meta_path, context.temp_allocator)
	if merr != nil do return
	Meta :: struct { guid: string }
	meta: Meta
	if json.unmarshal(meta_bytes, &meta, .JSON, context.temp_allocator) != nil do return
	id, err := uuid.read(meta.guid)
	if err != nil do return

	data, derr := os.read_entire_file(path, context.temp_allocator)
	if derr != nil do return
	clip: anim.AnimationClip
	if json.unmarshal(data, &clip, .JSON, context.allocator) != nil do return
	anim.animation_clip_cache[engine.Asset_GUID(id)] = clip
}

// A viewer asks which graph belongs to an object rather than naming owners.
// A TimelineAnimator outranks an Animation on the same object: it is the more
// concrete driver, so it is the one actually posing.
@(test)
test_graph_provider_prefers_the_concrete_driver :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()
	anim.playable_graph_providers_init()

	guid := _clip_guid(61)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {1, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, b_raw := engine.transform_add_comp(root, .Animation)
	a_comp := cast(^anim.Animation)b_raw
	a_comp.enabled = true

	// Nothing has built a graph yet, so no runtime provider claims it.
	_, found := anim.playable_graph_for_object(root)
	testing.expect(t, !found, "an object with no built graph is not claimed")

	// The Animation builds one when it plays.
	anim.animation_play_clip(a_comp, guid)
	src, ok := anim.playable_graph_for_object(root)
	testing.expect(t, ok, "a playing Animation is claimed")
	testing.expect(t, src.graph == &a_comp.graph, "and it reports that component's graph")
	testing.expect(t, src.live, "a runtime graph is live")

	// A TimelineAnimator on the same object takes over the report once built.
	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	anim.timeline_animator_tick(0)

	src2, ok2 := anim.playable_graph_for_object(root)
	testing.expect(t, ok2, "the object is still claimed")
	testing.expect(t, src2.graph == &ta.graph,
		"the TimelineAnimator outranks the Animation under it")
	testing.expect(t, src2.order < src.order, "and does so by provider order")
}

// A director's animation tracks share one arena, and that is the graph a
// viewer should show for the director — including when an animator adopted it,
// where the tracks build into the ANIMATOR's graph instead.
@(test)
test_graph_provider_reports_director_arena :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()
	anim.playable_graph_providers_init()

	guid := _clip_guid(62)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {2, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)
	tl := _mk_local_timeline(root, b_owned.handle, guid)

	// Standalone: the arena is the director's own.
	_, d := engine.transform_get_comp(tl, seq.PlayableDirector)
	seq.director_evaluate_at(d, 0.5, .Play)
	src, ok := anim.playable_graph_for_object(tl)
	testing.expect(t, ok, "a director with animation tracks is claimed")
	testing.expect(t, src.graph == anim.animation_director_graph(tl), "it reports its own arena")

	// Adopted: the tracks live in the animator's graph, so that is what a
	// viewer must show — the director's own arena graph is empty. A state
	// naming the timeline is what adopts it, and what gives Body its output.
	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("Idle", tl))
	append(&ta.layers, layer)
	anim.timeline_animator_tick(0)

	src2, ok2 := anim.playable_graph_for_object(tl)
	testing.expect(t, ok2, "an adopted director is still claimed")
	testing.expect(t, src2.graph == &ta.graph, "and reports the adopter's graph")
}

// A Once state runs to its end and REPORTS it, so gameplay can hand back to
// whatever should follow. A Loop state never does.
@(test)
test_once_state_reports_done :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	guid := _clip_guid(71)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {5, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)

	looping := _mk_state("Looping", _mk_local_timeline(root, b_owned.handle, guid))
	once := _mk_state("Once", _mk_local_timeline(root, b_owned.handle, guid))
	once.wrap = .Once
	append(&layer.states, looping)
	append(&layer.states, once)
	append(&ta.layers, layer)

	loop_id, _ := anim.animator_find(ta, "Looping")
	once_id, _ := anim.animator_find(ta, "Once")

	// A looping state runs past its length without ever finishing.
	anim.animator_play(ta, loop_id, 0)
	anim.timeline_animator_tick(2.5)
	_, _, loop_done := anim.animator_state(ta)
	testing.expect(t, !loop_done, "a Loop state never reports done")

	// A Once state does, and stays there.
	anim.animator_play(ta, once_id, 0)
	anim.timeline_animator_tick(0.5)
	_, mid, done_mid := anim.animator_state(ta)
	testing.expect(t, !done_mid, "mid-clip is not done")
	testing.expectf(t, abs(mid - 0.5) < 0.01, "normalized time tracks the playhead, got %v", mid)

	anim.timeline_animator_tick(1.0)
	lead, _, done := anim.animator_state(ta)
	testing.expect_value(t, lead, once_id)
	testing.expect(t, done, "a Once state past its end reports done")

	anim.timeline_animator_tick(1.0)
	_, _, still := anim.animator_state(ta)
	testing.expect(t, still, "and keeps reporting it until something replaces it")
}

// A one-shot must be replayable. Playing always starts the target at time 0 —
// a finished Once state that resumed where it stopped would report done again
// on the next tick and never be seen.
@(test)
test_replaying_a_finished_once_state_rewinds :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	guid := _clip_guid(72)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {5, 0, 0, 0})

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("Idle", _mk_local_timeline(root, b_owned.handle, guid)))
	shot := _mk_state("Shot", _mk_local_timeline(root, b_owned.handle, guid))
	shot.wrap = .Once
	append(&layer.states, shot)
	append(&ta.layers, layer)

	idle, _ := anim.animator_find(ta, "Idle")
	one_shot, _ := anim.animator_find(ta, "Shot")

	// Run it to the end.
	anim.animator_play(ta, one_shot, 0)
	anim.timeline_animator_tick(2)
	_, _, done := anim.animator_state(ta)
	testing.expect(t, done, "the one-shot finished")

	// Hand back, then trigger it again WITH A FADE — the path that used to
	// clear `done` without rewinding.
	anim.animator_play(ta, idle, 0)
	anim.timeline_animator_tick(0.1)
	anim.animator_play(ta, one_shot, 0.2)
	anim.timeline_animator_tick(0.25)

	lead, normalized, done2 := anim.animator_state(ta)
	testing.expect_value(t, lead, one_shot)
	testing.expect(t, !done2, "a replayed one-shot is not instantly finished again")
	testing.expectf(t, normalized < 0.5, "and starts near the beginning, got %v", normalized)

	// Play means play: a state that is already leading still restarts.
	anim.animator_play(ta, idle, 0)
	anim.timeline_animator_tick(0.6)
	_, before, _ := anim.animator_state(ta)
	testing.expect(t, before > 0.1, "the looping state has advanced")
	anim.animator_play(ta, idle, 0.2)
	anim.timeline_animator_tick(0.05)
	_, after, _ := anim.animator_state(ta)
	testing.expectf(t, after < before,
		"playing a state restarts it from 0, %v -> %v", before, after)
}

// A State_Id names a state, not a position. It used to be layer<<16|index into
// arrays kept parallel to the authored list, so deleting an earlier state on
// the same layer silently repointed every id after it — a handle taken before
// the edit then played the wrong timeline. Ids are minted and never reused now.
@(test)
test_state_id_survives_deleting_an_earlier_state :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	anim.animation_track_init()

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	b_owned, _ := engine.transform_add_comp(body, .Animation)
	guid := _clip_guid(90)
	anim.animation_clip_cache[guid] = _const_clip(.Position, {5, 0, 0, 0}, 1, .Loop)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.speed = 1
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("First", _mk_local_timeline(root, b_owned.handle, guid)))
	append(&layer.states, _mk_state("Second", _mk_local_timeline(root, b_owned.handle, guid)))
	append(&ta.layers, layer)

	second, ok := anim.animator_find(ta, "Second")
	testing.expect(t, ok, "the second state resolves by name")
	if !ok do return

	// Delete the state BEFORE it. Under the old scheme `second` now named the
	// state that moved into index 0.
	delete(ta.layers[0].states[0].name)
	ordered_remove(&ta.layers[0].states, 0)

	again, still := anim.animator_find(ta, "Second")
	testing.expect(t, still, "it still resolves by name after the delete")
	testing.expect_value(t, again, second)

	_, _, desc_name := _state_name_of(ta, second)
	testing.expect_value(t, desc_name, "Second")
}

// The authored name behind a State_Id, for asserting which state an id means.
@(private = "file")
_state_name_of :: proc(a: ^anim.TimelineAnimator, id: anim.State_Id) -> (layer: int, index: int, name: string) {
	for &l, li in a.layers {
		for &st, si in l.states {
			if anim.State_Id(st.id) == id do return li, si, st.name
		}
	}
	return -1, -1, ""
}

// The binding a driver's inspector draws is READ OFF THE TRACK STRUCT — field
// type, pointer and picker tags — from nothing but the registered name, so
// the proxy row and the track's own inspector cannot disagree.
@(test)
test_track_binding_resolves_from_struct :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	body := engine.transform_new("Body")
	b_owned, _ := engine.transform_add_comp(body, .Animation)
	tl := _mk_local_timeline(engine.Transform_Handle(tc.scene.root.handle), b_owned.handle, {})
	_, draw := engine.transform_get_comp_key(tl, .PlayableDirector)
	tracks := seq.director_tracks(cast(^seq.PlayableDirector)draw)
	testing.expect_value(t, len(tracks), 1)
	if len(tracks) != 1 do return

	desc, dok := seq.track_desc(tracks[0].kind)
	testing.expect(t, dok && desc.binding_field == "target", "the animation track registers its target")
	track_owned, ta := engine.transform_get_comp(tracks[0].node, anim.TrackAnimation)
	p, pok := inspector.inspect_comp(track_owned.handle)
	testing.expect(t, pok)
	if !pok do return
	b, err := inspector.property(p, desc.binding_field)
	testing.expect_value(t, err, inspector.Resolve_Error.None)
	if err != .None do return
	testing.expect(t, b.ptr == rawptr(&ta.target), "the pointer is the track's own target field")
	testing.expect(t, b.tid == typeid_of(engine.Ref_Local), "the type is the field's")
	testing.expect_value(t, b.record.path, "target")
	testing.expect(t, b.owner.handle == track_owned.handle, "undo owner is the track component")
	ref, has_ref := reflect.struct_tag_lookup(b.tag, "ref")
	testing.expect(t, has_ref && ref == "Animation", "the picker tag is the struct's, not a copy")
}
