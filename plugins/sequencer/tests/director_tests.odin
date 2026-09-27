package sequencer_tests

// PlayableDirector on the timeline-as-prefab model: the timeline IS the
// director's subtree — track nodes as children, clip nodes under them.
// Headless coverage: playback across kinds, manual start, Once/Loop, scrub
// silence, target round trip through Simulate's snapshot/restore, the
// activation preview restore, and the control track driving a nested
// director.

import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"
// Build a track NODE with clip NODES under `owner` — what the window's Add
// Track/Add Clip produce. Reuses the view struct as the clip parameter.
_mk_track :: proc(owner: engine.Transform_Handle, kind: engine.TypeKey, clips: ..seq.Clip_View) -> engine.Transform_Handle {
	desc, _ := seq.track_desc(kind)
	node := engine.transform_new(desc.label, owner)
	engine.transform_get_or_add_comp(node, seq.TimelineTrack)
	engine.transform_add_comp(node, kind)
	for c in clips {
		cn := engine.transform_new(len(c.name) > 0 ? c.name : "clip", node)
		_, cc := engine.transform_get_or_add_comp(cn, seq.TimelineClip)
		cc.start = c.start
		cc.duration = c.duration
		cc.ease_in = c.ease_in
		cc.ease_out = c.ease_out
		cc.speed = c.speed
		if desc.clip_key != engine.INVALID_TYPE_KEY do engine.transform_add_comp(cn, desc.clip_key)
	}
	return node
}

// Point an activation track at a transform.
_set_activation_target :: proc(node: engine.Transform_Handle, target: engine.Ref_Local) {
	if _, at := seq.get_comp(node, seq.TrackActivation); at != nil do at.target = target
}

// A track's target must survive the Simulate round trip (serialize the
// scene, reload it in place — what Play/Stop does). The target is an
// ordinary component field now, so this covers the whole timeline subtree.
@(test)
test_track_target_survives_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Target", root)

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, ct != nil)
	if ct == nil do return
	act := _mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	_set_activation_target(act, {local_id = ct.local_id, handle = engine.Handle(child)})
	want_lid := ct.local_id
	testing.expect(t, want_lid != 0, "the target must have a local id")

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "snapshot should capture")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "restore should load")
	if reloaded == nil do return
	tc.scene = reloaded

	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil, "director survives the round trip")
	if d2 == nil do return
	tracks := seq.director_tracks(d2)
	testing.expect_value(t, len(tracks), 1)
	if len(tracks) != 1 do return
	_, at2 := seq.get_comp(tracks[0].node, seq.TrackActivation)
	testing.expect(t, at2 != nil, "the kind component survives")
	if at2 == nil do return
	testing.expect_value(t, at2.target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, at2.target.handle),
		"the target handle must re-resolve after restore")
	testing.expect_value(t, len(tracks[0].clips), 1)
}

// The activation track owns its preview restore: outside Play mode the tick
// captures the pre-tick is_active and preview_end writes it back — including
// an authored-INACTIVE object.
@(test)
test_activation_preview_restores_authored_state :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 2
	defer seq.director_teardown(d)

	act := _mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	_set_activation_target(act, {handle = engine.Handle(child)})

	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	ct.is_active = false // authored INACTIVE

	// One preview frame: scrub inside the span activates, restore un-does it.
	seq.director_set_time(d, 0.5)
	testing.expect(t, ct.is_active, "the span activates the target during preview")
	seq.director_preview_end(d)
	testing.expect(t, !ct.is_active, "preview restore returns the AUTHORED state, not true")

	// Same through the preview-play per-frame bracket.
	seq.director_preview_step(d, 0.4)
	seq.director_preview_end(d, playing = true)
	testing.expect(t, !ct.is_active, "per-frame restore while playing also returns authored state")

	// The runtime path never captures — play mode leaves the tick's result.
	ct.is_active = true
	seq.director_tick(d, 0.5)
	testing.expect(t, ct.is_active, "runtime play drives activation directly")
}

// Overlap IS the blend (Unity's Timeline model): where two clips on a track
// overlap, the earlier ramps out across the overlap while the later ramps
// in, with no authoring. Explicit eases still apply at boundaries with no
// neighbour. Derived from the spans, so it can never disagree with them.
@(test)
test_clip_weight_overlap_crossfades :: proc(t: ^testing.T) {
	// A [0,2), B [1,3) — a 1s overlap in [1,2).
	clips := []seq.Clip_View{
		{start = 0, duration = 2},
		{start = 1, duration = 2},
	}

	// Outside the overlap both sit at full weight.
	testing.expect(t, seq.track_clip_weight(clips, 0, 0.5) == 1, "A is full before the overlap")
	testing.expect(t, seq.track_clip_weight(clips, 1, 2.5) == 1, "B is full after the overlap")

	// Mid-overlap they meet at 0.5 — a symmetric crossfade.
	a_mid := seq.track_clip_weight(clips, 0, 1.5)
	b_mid := seq.track_clip_weight(clips, 1, 1.5)
	testing.expect(t, abs(a_mid - 0.5) < 0.001, "A is half way out at the overlap centre")
	testing.expect(t, abs(b_mid - 0.5) < 0.001, "B is half way in at the overlap centre")

	// The pair sums to 1 across the whole overlap: no dip, no double.
	for i in 0 ..= 10 {
		time := 1 + f32(i) / 10 * 0.999
		sum := seq.track_clip_weight(clips, 0, time) + seq.track_clip_weight(clips, 1, time)
		testing.expectf(t, abs(sum - 1) < 0.001, "weights must sum to 1 at t=%.2f, got %.3f", time, sum)
	}

	// Outside every span: nothing.
	testing.expect(t, seq.track_clip_weight(clips, 0, 2.5) == 0, "A is silent past its end")
	testing.expect(t, seq.track_clip_weight(clips, 1, 0.5) == 0, "B is silent before its start")
}

// An explicit ease with no neighbour still ramps, and an overlap wider than
// the authored ease wins (the clips actually overlap that much).
@(test)
test_clip_weight_explicit_ease :: proc(t: ^testing.T) {
	solo := []seq.Clip_View{{start = 0, duration = 2, ease_in = 1, ease_out = 0.5}}
	testing.expect(t, abs(seq.track_clip_weight(solo, 0, 0.5) - 0.5) < 0.001, "ease_in ramps up")
	testing.expect(t, seq.track_clip_weight(solo, 0, 1.2) == 1, "full weight between the ramps")
	testing.expect(t, abs(seq.track_clip_weight(solo, 0, 1.75) - 0.5) < 0.001, "ease_out ramps down")

	// A 1s overlap beats a 0.2s authored ease_in on the later clip.
	pair := []seq.Clip_View{
		{start = 0, duration = 2},
		{start = 1, duration = 2, ease_in = 0.2},
	}
	testing.expect(t, abs(seq.track_clip_weight(pair, 1, 1.5) - 0.5) < 0.001,
		"the overlap drives the blend, not the smaller authored ease")
}

// CROSS-BOUNDARY TARGETS: a timeline PREFAB instanced into a host scene,
// with its track bound to a HOST-SCENE object. This is what makes a timeline
// reusable — the prefab knows nothing about the host, the instance binds it,
// and the binding persists as an ordinary prefab OVERRIDE.
//
// The binding must be recorded, not just assigned: the inspector records at
// every field commit, and a bare mutation on nested content is not saved.
@(test)
test_timeline_prefab_instance_targets_host_object :: proc(t: ^testing.T) {
	dir := "moonhug/tests/_test_tl_xboundary"
	os.make_directory(dir)
	tl_path := strings.concatenate({dir, "/tl.scene"}, context.temp_allocator)
	defer {
		os.remove(tl_path)
		os.remove(strings.concatenate({tl_path, ".meta"}, context.temp_allocator))
		os.remove(dir)
	}

	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.register_builtin_tracks()

	// Author a timeline prefab with an UNBOUND activation track.
	root := engine.transform_new("TL")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.duration = 2
	_mk_track(root, .TrackActivation, seq.Clip_View{start = 0, duration = 1})
	testing.expect(t, engine.scene_save(tc.scene, tl_path), "prefab saved")

	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer engine.scene_lib_shutdown()
	tl_guid, gok := engine.asset_db_get_guid(tl_path)
	testing.expect(t, gok, "prefab registered")
	if !gok do return

	// Host scene with an actor and an instance of the prefab.
	host := engine.scene_load_single_path(tl_path)
	testing.expect(t, host != nil)
	if host == nil do return
	tc.scene = host
	hroot := engine.Transform_Handle(host.root.handle)
	actor := engine.transform_new("Actor", hroot)
	aT := engine.pool_get(&tc.world.transforms, engine.Handle(actor))

	inst := engine.scene_instantiate_guid_nested(engine.Asset_GUID(tl_guid), hroot)
	testing.expect(t, inst != {}, "prefab instantiates")
	if inst == {} do return

	// The instance's track, bound to the HOST's actor and RECORDED.
	track: engine.Transform_Handle
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _, h in engine.pool_next(&it) {
			hh := h
			hh.type_key = .Transform
			if _, a := seq.get_comp(engine.Transform_Handle(hh), seq.TrackActivation); a != nil {
				track = engine.Transform_Handle(hh)
			}
		}
	}
	testing.expect(t, track != {}, "the instance has the activation track")
	if track == {} do return
	owned, act := seq.get_comp(track, seq.TrackActivation)
	act.target = {local_id = aT.local_id, handle = engine.Handle(actor)}
	_, rok := engine.nested_scene_record_override_for_host(
		host, inst, owned.local_id, "target", &act.target, typeid_of(engine.Ref_Local))
	testing.expect(t, rok, "the host binding records as a prefab override")

	// It drives the host object.
	di: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do di = dd
	}
	testing.expect(t, di != nil)
	if di == nil do return
	defer seq.director_teardown(di)
	aT.is_active = false
	seq.director_set_time(di, 0.5)
	testing.expect(t, aT.is_active, "the instance's track drives the HOST object")

	// And survives the Play/Stop round trip.
	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc.scene = reloaded

	found := false
	{
		it := engine.pool_iterator(&tc.world.transforms)
		for _, h in engine.pool_next(&it) {
			hh := h
			hh.type_key = .Transform
			if _, a := seq.get_comp(engine.Transform_Handle(hh), seq.TrackActivation); a != nil {
				found = true
				testing.expect(t, a.target.local_id != 0, "the host binding survived reload")
				testing.expect(t, engine.world_pool_valid(&tc.world, a.target.handle),
					"and re-resolves to a live host object")
			}
		}
	}
	testing.expect(t, found, "the instance survives reload")
}
