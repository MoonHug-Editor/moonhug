package animation_tests

// TimelineAnimator (docs/TimelineAnimator.md): the component's graph skeleton —
// one output per bound target, a layer mixer at each output's root, one mixer
// per layer under it.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

// Strings on a component are owned by it: cleanup_TimelineAnimator frees them,
// so a test may not hand it a literal.
@(private = "file")
_ta_target :: proc(key: string, h: engine.Handle) -> anim.Target_Binding {
	return {key = strings.clone(key), target = {handle = h}}
}

@(test)
test_timeline_animator_graph_skeleton :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	face := engine.transform_new("Face", root)

	b_owned, _ := engine.transform_add_comp(body, .Animation)
	f_owned, _ := engine.transform_add_comp(face, .Animation)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	append(&ta.targets, _ta_target("Face", f_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Base")})
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Upper"), weight = 0.5})

	anim.timeline_animator_tick(0)

	testing.expect_value(t, len(ta.graph.outputs), 2)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Face"), 1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Missing"), -1)

	for oi in 0 ..< 2 {
		o := anim.graph_output(&ta.graph, oi)
		testing.expect(t, o != nil, "every bound target has an output")
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

@(test)
test_timeline_animator_skips_unbound_targets :: proc(t: ^testing.T) {
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
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Nothing", {})) // never bound
	append(&ta.targets, _ta_target("Body", b_owned.handle))

	anim.timeline_animator_tick(0)

	// A key with no component behind it produces no output, and the keys that
	// do resolve are unaffected by its position in the list.
	testing.expect_value(t, len(ta.graph.outputs), 1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Nothing"), -1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
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
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Base")})

	bt := engine.pool_get(&tc.world.transforms, engine.Handle(body))
	bt.position = {3, 0, 0}

	// No state is attached to any layer mixer, so the graph would evaluate to
	// an empty pose. Applying that would write bind-time defaults over whatever
	// else poses the object, so an idle animator must not apply at all.
	anim.timeline_animator_tick(0)
	anim.timeline_animator_tick(0)

	testing.expect(t, abs(bt.position.x - 3) < 0.001,
		"an animator with no states does not touch its targets")
}

// A timeline living in the scene: a director with one animation track keyed to
// `key`, playing `clip` across its whole length. Cheaper than a prefab fixture
// and exercises the local-reference form a state supports.
@(private = "file")
_mk_local_timeline :: proc(parent: engine.Transform_Handle, key: string, clip: engine.Asset_GUID, length: f32 = 1) -> engine.Transform_Handle {
	tl := engine.transform_new("Timeline", parent)
	_, draw := engine.transform_add_comp(tl, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw
	d.enabled = true
	d.duration = length
	d.wrap = .Loop

	track := engine.transform_new("animation", tl)
	engine.transform_get_or_add_comp(track, seq.TimelineTrack)
	_, traw := engine.transform_add_comp(track, .TrackAnimation)
	(cast(^anim.TrackAnimation)traw).key = strings.clone(key)

	cn := engine.transform_new("clip", track)
	_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
	cc.start = 0
	cc.duration = length
	_, ca := engine.transform_add_comp(cn, .ClipAnimation)
	(cast(^anim.ClipAnimation)ca).clip = clip
	return tl
}

@(private = "file")
_mk_state :: proc(name: string, tl: engine.Transform_Handle, fade: f32 = 0) -> anim.Timeline_State {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tl))
	return {
		name     = strings.clone(name),
		timeline = {local_id = t.local_id},
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
	b_owned, _ := engine.transform_add_comp(body, .Animation)

	tl := engine.transform_new("Timeline", root)
	_, draw := engine.transform_add_comp(tl, .PlayableDirector)
	(cast(^seq.PlayableDirector)draw).enabled = true
	tlt := engine.pool_get(&tc.world.transforms, engine.Handle(tl))
	lid := tlt.local_id

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, anim.Timeline_State{
		name     = strings.clone("Idle"),
		timeline = {local_id = lid}, // guid zero: a local reference
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
@(test)
test_state_play_poses_keyed_target :: proc(t: ^testing.T) {
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

	tl := _mk_local_timeline(root, "Body", guid)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
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
		"playing a state poses the key's target through the animator")
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

	tl_a := _mk_local_timeline(root, "Body", lo)
	tl_b := _mk_local_timeline(root, "Body", hi)

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
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
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, _mk_state("A", _mk_local_timeline(root, "Body", ga)))
	append(&layer.states, _mk_state("B", _mk_local_timeline(root, "Body", gb)))
	append(&layer.states, _mk_state("C", _mk_local_timeline(root, "Body", gc)))
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
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	st := _mk_state("Fast", _mk_local_timeline(root, "Body", guid, 10))
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
	ta.targets = make([dynamic]anim.Target_Binding)
	append(&ta.targets, _ta_target("Body", b_owned.handle))
	append(&ta.targets, _ta_target("Inner", i_owned.handle))
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	// The track asks for "Face", which nothing binds.
	append(&layer.states, _mk_state("Bad", _mk_local_timeline(root, "Face", guid)))
	append(&ta.layers, layer)

	anim.timeline_animator_tick(0)
	problems := anim.timeline_animator_problems(ta)

	unbound, overlap := 0, 0
	for p in problems {
		switch p.kind {
		case .Unbound_Key:      if p.key == "Face" do unbound += 1
		case .Overlapping_Pose: overlap += 1
		}
	}
	testing.expect(t, unbound == 1, "a key nothing binds is reported")
	testing.expect(t, overlap == 1, "two pose outputs that overlap are reported")
}

// The shipped sample scene is hand-generated JSON, which is exactly the kind of
// asset that rots silently. Loading it here catches a renamed field or a bad
// local_id at test time instead of when someone opens it.
@(test)
test_animator_sample_scene_loads :: proc(t: ^testing.T) {
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
	_load_sample_clip("plugins/animation/samples/timeline_sample/assets/lean_left.anim")
	_load_sample_clip("plugins/animation/samples/timeline_sample/assets/lean_right.anim")

	PATH :: "plugins/animation/samples/timeline_sample/assets/animator_demo.scene"
	s := engine.scene_load_single_path(PATH)
	testing.expect(t, s != nil, "the sample scene parses and loads")
	if s == nil do return
	tc.scene = s

	root := engine.Transform_Handle(s.root.handle)
	_, ta := engine.transform_get_comp(root, anim.TimelineAnimator)
	testing.expect(t, ta != nil, "the root carries a TimelineAnimator")
	if ta == nil do return

	testing.expect_value(t, len(ta.targets), 1)
	testing.expect_value(t, len(ta.layers), 1)
	testing.expect_value(t, len(ta.layers[0].states), 2)

	// Building resolves the key binding and both state timelines.
	anim.timeline_animator_tick(0)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
	_, l_ok := anim.animator_find(ta, "LeanLeft")
	_, r_ok := anim.animator_find(ta, "LeanRight")
	testing.expect(t, l_ok && r_ok, "both states resolve by name")

	// And the authored wiring has no problems: every track key is bound and no
	// two pose outputs overlap.
	testing.expect_value(t, len(anim.timeline_animator_problems(ta)), 0)

	// End to end, so none of the above can pass on a state whose timeline
	// never resolved: playing LeanLeft must actually move Body. The clip puts
	// x at -2.5 halfway through.
	bt: ^engine.Transform
	if rt := engine.pool_get(&tc.world.transforms, engine.Handle(root)); rt != nil {
		for ch in rt.children {
			c := engine.pool_get(&tc.world.transforms, ch.handle)
			if c != nil && c.name == "Body" do bt = c
		}
	}
	testing.expect(t, bt != nil, "the sample has a Body object")
	if bt == nil do return

	id, _ := anim.animator_find(ta, "LeanLeft")
	anim.animator_play(ta, id, 0)
	anim.timeline_animator_tick(0.5)
	testing.expectf(t, abs(bt.position.x - (-2.5)) < 0.01,
		"playing a sample state poses Body, got %v", bt.position.x)
}

// Read a .anim and its .meta straight into the clip cache, bypassing the asset
// DB. Only for tests that load shipped sample assets by path.
@(private = "file")
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
