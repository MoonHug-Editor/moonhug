package sequencer_tests

// PlayableDirector: timeline playback headless — animation track crossfades
// through the graph, activation spans, marker crossings (with loop wrap),
// manual start, Once stop, and the scrub path.

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

_clip_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: engine.Asset_GUID
	id[15] = n
	id[0] = 0xAA
	return id
}

// A constant single-key clip: owner `prop` = `value` for its whole length.
_const_clip :: proc(path: anim.Animation_Path, value: [4]f32, length: f32 = 1, wrap: anim.Animation_Wrap = .Loop) -> anim.AnimationClip {
	clip := anim.AnimationClip{length = length, wrap = wrap}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, value)
	append(&clip.channels, ch)
	return clip
}

// A two-key linear ramp clip: `prop` goes a -> b over `length`.
_ramp_clip :: proc(path: anim.Animation_Path, a, b: [4]f32, length: f32 = 1, wrap: anim.Animation_Wrap = .Once) -> anim.AnimationClip {
	clip := anim.AnimationClip{length = length, wrap = wrap}
	clip.channels = make([dynamic]anim.Animation_Channel)
	ch := anim.Animation_Channel{path = path}
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0, length)
	append(&ch.values, a, b)
	append(&clip.channels, ch)
	return clip
}

_tl_guid :: proc(n: u8) -> engine.Asset_GUID {
	id: engine.Asset_GUID
	id[15] = n
	id[0] = 0xBB
	return id
}

@(private = "file")
_track :: proc(kind: string, clips: ..seq.Timeline_Clip) -> seq.Timeline_Track {
	t := seq.Timeline_Track{kind = strings.clone(kind), name = strings.clone(kind)}
	t.clips = make([dynamic]seq.Timeline_Clip)
	for c in clips {
		cc := c
		cc.name = strings.clone(c.name)
		append(&t.clips, cc)
	}
	return t
}

@(private = "file") _marker_hits: int

@(private = "file")
_count_marker :: proc(name: string, target: engine.Ref_Local) {
	_marker_hits += 1
}

@(test)
test_director_playback :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()
	anim.animation_track_init()

	// Clips: a ramp x 0->10 over 1s, and a constant x=4.
	ramp_guid, const_guid := _clip_guid(10), _clip_guid(11)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	anim.animation_clip_cache[const_guid] = _const_clip(.Position, {4, 0, 0, 0})

	// Timeline: anim clip A [0,1), anim clip B [1,2), an activation span
	// [0.5, 1.5) on a child, a marker at 0.5. Loops at duration 2.
	tl := seq.Timeline{duration = 2}
	tl.tracks = make([dynamic]seq.Timeline_Track)
	append(&tl.tracks, _track("animation",
		seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid},
		seq.Timeline_Clip{start = 1, duration = 1, asset = const_guid},
	))
	append(&tl.tracks, _track("activation", seq.Timeline_Clip{start = 0.5, duration = 1}))
	append(&tl.tracks, _track("marker", seq.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(1)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	append(&d.bindings, seq.Track_Binding{track = 1, target = {handle = engine.Handle(child)}})

	_marker_hits = 0
	seq.timeline_marker_hook = _count_marker
	defer seq.timeline_marker_hook = nil

	// t = 0.5: ramp samples 5, activation just began, marker crossed once.
	for _ in 0 ..< 5 do seq.director_tick(d, 0.1)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, abs(rt.position.x - 5) < 0.11, "animation track must drive the pose")
	testing.expect(t, ct.is_active, "activation span must activate the child")

	// t = 1.5: clip B active (x = 4), activation span ended, the marker's
	// [0.5, 0.6) window was crossed once on the way.
	for _ in 0 ..< 10 do seq.director_tick(d, 0.1)
	testing.expect(t, abs(rt.position.x - 4) < 0.001, "second clip must take over")
	testing.expect(t, !ct.is_active, "activation must end outside its span")
	testing.expect_value(t, _marker_hits, 1)

	// Loop wrap: after another full cycle the marker fired again.
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1)
	testing.expect_value(t, _marker_hits, 2)
}

@(test)
test_director_control_and_scrub :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()
	anim.animation_track_init()

	ramp_guid := _clip_guid(12)
	anim.animation_clip_cache[ramp_guid] = _ramp_clip(.Position, {0, 0, 0, 0}, {10, 0, 0, 0})
	tl := seq.Timeline{duration = 1}
	tl.tracks = make([dynamic]seq.Timeline_Track)
	append(&tl.tracks, _track("animation", seq.Timeline_Clip{start = 0, duration = 1, asset = ramp_guid}))
	append(&tl.tracks, _track("marker", seq.Timeline_Clip{start = 0.5, name = "hit"}))
	guid := _tl_guid(2)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	d.wrap = .Once
	d.manual_start = true

	// Manual start holds playback until director_play.
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 0)
	seq.director_play(d)
	for _ in 0 ..< 3 do seq.director_tick(d, 0.1)
	testing.expect(t, d.time > 0.29, "play must start advancing")

	// Once: clamps at the duration and stops.
	for _ in 0 ..< 20 do seq.director_tick(d, 0.1)
	testing.expect_value(t, d.time, 1)
	testing.expect(t, !d.playing, "Once must stop at the end")

	// Scrub: jump to 0.3 evaluates the pose, markers stay silent.
	_marker_hits = 0
	seq.timeline_marker_hook = _count_marker
	defer seq.timeline_marker_hook = nil
	seq.director_set_time(d, 0.3)
	rt := engine.pool_get(&tc.world.transforms, engine.Handle(root))
	testing.expect(t, abs(rt.position.x - 3) < 0.001, "scrub must evaluate the pose at the set time")
	seq.director_set_time(d, 0.7)
	testing.expect_value(t, _marker_hits, 0)
}

// A director binding must survive the Simulate round trip (serialize the
// scene, reload it in place — what Play/Stop does).
@(test)
test_director_binding_survives_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Target", root)
	owned, _ := engine.transform_add_comp(child, .Transform)
	_ = owned

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	// Bind track 0 to the child transform (an activation-style binding).
	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	testing.expect(t, ct != nil)
	if ct == nil do return
	append(&d.bindings, seq.Track_Binding{
		track = 0,
		target = {local_id = ct.local_id, handle = engine.Handle(child)},
	})
	want_lid := ct.local_id
	testing.expect(t, want_lid != 0, "the target must have a local id")

	// Serialize + reload in place, exactly like Simulate's snapshot/restore.
	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok, "snapshot should capture")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil, "restore should load")
	if reloaded == nil do return
	tc.scene = reloaded

	// The restored director must still name the target.
	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil, "director survives the round trip")
	if d2 == nil do return
	testing.expect_value(t, len(d2.bindings), 1)
	if len(d2.bindings) != 1 do return
	testing.expect_value(t, d2.bindings[0].target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, d2.bindings[0].target.handle),
		"the binding handle must re-resolve after restore")
}

// The activation track owns its preview restore: outside Play mode the tick
// captures the pre-tick is_active and preview_end writes it back — including
// an authored-INACTIVE object, which the old force-to-true restore left
// visible after the preview.
@(test)
test_activation_preview_restores_authored_state :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()

	tl := seq.Timeline{duration = 2}
	tl.tracks = make([dynamic]seq.Timeline_Track)
	append(&tl.tracks, _track("activation", seq.Timeline_Clip{start = 0, duration = 1}))
	guid := _tl_guid(7)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Child", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	append(&d.bindings, seq.Track_Binding{track = 0, target = {handle = engine.Handle(child)}})
	defer seq.director_teardown(d)

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

// Exposed references (Unity's ExposedReference): the TIMELINE declares named
// slots, the DIRECTOR fills them, and a track whose `exposed` names a slot
// resolves its target through the table — several tracks can share one slot,
// and an unbound slot targets nothing.
@(test)
test_exposed_slot_resolution :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_clip_cache_init()
	defer anim.animation_clip_cache_shutdown()
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()

	// Two activation tracks share the "hero" slot; a third stays direct.
	tl := seq.Timeline{duration = 2}
	tl.exposed_names = make([dynamic]string)
	append(&tl.exposed_names, strings.clone("hero"))
	tl.tracks = make([dynamic]seq.Timeline_Track)
	t0 := _track("activation", seq.Timeline_Clip{start = 0, duration = 1})
	t0.exposed = strings.clone("hero")
	append(&tl.tracks, t0)
	t1 := _track("activation", seq.Timeline_Clip{start = 0, duration = 1})
	t1.exposed = strings.clone("hero")
	append(&tl.tracks, t1)
	append(&tl.tracks, _track("activation", seq.Timeline_Clip{start = 0, duration = 1}))
	guid := _tl_guid(8)
	seq.timeline_cache[guid] = tl

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	hero := engine.transform_new("Hero", root)
	direct := engine.transform_new("Direct", root)

	_, raw := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)raw
	d.enabled = true
	d.timeline = {guid = guid}
	append(&d.exposed, seq.Exposed_Binding{name = strings.clone("hero"), target = {handle = engine.Handle(hero)}})
	append(&d.bindings, seq.Track_Binding{track = 2, target = {handle = engine.Handle(direct)}})
	defer seq.director_teardown(d)

	ht := engine.pool_get(&tc.world.transforms, engine.Handle(hero))
	dt := engine.pool_get(&tc.world.transforms, engine.Handle(direct))
	ht.is_active = false
	dt.is_active = false

	// Inside the span both the slot-bound tracks and the direct one activate
	// their targets — the slot resolves for BOTH sharing tracks.
	seq.director_tick(d, 0.5)
	testing.expect(t, ht.is_active, "slot-bound tracks drive the slot's target")
	testing.expect(t, dt.is_active, "direct binding keeps working beside slots")

	// An unbound slot targets nothing: clear the table, nothing crashes and
	// the target stays untouched.
	for &e in d.exposed do delete(e.name)
	clear(&d.exposed)
	ht.is_active = false
	seq.director_tick(d, 0.1)
	testing.expect(t, !ht.is_active, "an unbound slot drives nothing")
}

// The exposed table survives the scene round trip like track bindings do —
// name and target re-resolve by local id.
@(test)
test_exposed_binding_survives_serialize_roundtrip :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	seq.timeline_cache_init()
	defer seq.timeline_cache_shutdown()
	seq.register_builtin_tracks()

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc.scene, root)
	child := engine.transform_new("Target", root)

	_, draw_ := engine.transform_add_comp(root, .PlayableDirector)
	d := cast(^seq.PlayableDirector)draw_
	d.enabled = true

	ct := engine.pool_get(&tc.world.transforms, engine.Handle(child))
	append(&d.exposed, seq.Exposed_Binding{
		name   = strings.clone("hero"),
		target = {local_id = ct.local_id, handle = engine.Handle(child)},
	})
	want_lid := ct.local_id
	testing.expect(t, want_lid != 0)

	bytes, ok := engine.scene_serialize(tc.scene)
	testing.expect(t, ok)
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, bytes)
	testing.expect(t, reloaded != nil)
	if reloaded == nil do return
	tc.scene = reloaded

	d2: ^seq.PlayableDirector
	{
		it := engine.pool_iterator(seq.playable_directors(&tc.world))
		for dd, _ in engine.pool_next(&it) do d2 = dd
	}
	testing.expect(t, d2 != nil)
	if d2 == nil do return
	testing.expect_value(t, len(d2.exposed), 1)
	if len(d2.exposed) != 1 do return
	testing.expect(t, d2.exposed[0].name == "hero", "the slot name round-trips")
	testing.expect_value(t, d2.exposed[0].target.local_id, want_lid)
	testing.expect(t, engine.world_pool_valid(&tc.world, d2.exposed[0].target.handle),
		"the slot's handle re-resolves after restore")
}

// exposed_names and Timeline_Track.exposed ride the .timeline JSON.
@(test)
test_timeline_exposed_json_roundtrip :: proc(t: ^testing.T) {
	tl := seq.Timeline{duration = 2}
	tl.exposed_names = make([dynamic]string)
	append(&tl.exposed_names, strings.clone("hero"))
	tl.tracks = make([dynamic]seq.Timeline_Track)
	tr := _track("activation", seq.Timeline_Clip{start = 0, duration = 1})
	tr.exposed = strings.clone("hero")
	append(&tl.tracks, tr)
	defer seq._timeline_destroy(&tl)

	data, merr := json.marshal(tl, {}, context.temp_allocator)
	testing.expect(t, merr == nil)

	loaded: seq.Timeline
	uerr := json.unmarshal(data, &loaded, .JSON, context.allocator)
	defer seq._timeline_destroy(&loaded)
	testing.expect(t, uerr == nil)
	testing.expect_value(t, len(loaded.exposed_names), 1)
	testing.expect(t, len(loaded.exposed_names) == 1 && loaded.exposed_names[0] == "hero")
	testing.expect(t, len(loaded.tracks) == 1 && loaded.tracks[0].exposed == "hero")
}
