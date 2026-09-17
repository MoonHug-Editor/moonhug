package animation_tests

// Outputs are OBJECTS, and each track finds its own component on them
// (docs/TimelineAnimator.md, "Target keys"). What this pins:
//
//   - an object with an Animation is POSED: it gets a graph output
//   - an object without one is not: no graph output, no pose binding to write
//     bind-time defaults over it — but its key still resolves, which is all a
//     non-pose track needs
//   - a track in another plugin resolves a key through the sequencer's
//     resolver without importing this one; the audio track is that plugin,
//     and the assertion goes through seq.track_resolve_key exactly as it does
//
// The second point is the one that made the object model safe to open to any
// plugin: before it, every bound output was assumed to be an Animation and got
// a pose binding regardless.

import "core:strings"
import "core:testing"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"
import common "moonhug:tests/common"

@(private = "file")
_output :: proc(key: string, tH: engine.Transform_Handle) -> anim.Output_Binding {
	return {key = strings.clone(key), object = {handle = engine.Handle(tH)}}
}

@(test)
test_output_without_animation_is_not_posed :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	body := engine.transform_new("Body", root)
	engine.transform_add_comp(body, .Animation)
	voice := engine.transform_new("Voice", root)
	engine.transform_add_comp(voice, .AudioSource) // an output for its sound only

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.outputs = make([dynamic]anim.Output_Binding)
	append(&ta.outputs, _output("Body", body))
	append(&ta.outputs, _output("Voice", voice))
	ta.layers = make([dynamic]anim.Animator_Layer)
	append(&ta.layers, anim.Animator_Layer{name = strings.clone("Base")})

	vt := engine.pool_get(&tc.world.transforms, engine.Handle(voice))
	vt.position = {5, 0, 0}

	anim.timeline_animator_tick(0)

	// Posed: one graph output, for Body alone.
	testing.expect_value(t, len(ta.graph.outputs), 1)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Body"), 0)
	testing.expect_value(t, anim.timeline_animator_output_for_key(ta, "Voice"), -1)

	// Resolvable: both keys name their object.
	if tH, ok := anim.timeline_animator_output_owner_for_key(ta, "Voice"); testing.expect(t, ok, "an unposed key still resolves") {
		testing.expect_value(t, tH, voice)
	}

	// Untouched: no binding exists to write defaults over the voice object.
	anim.timeline_animator_tick(0)
	testing.expect(t, abs(vt.position.x - 5) < 0.001, "an unposed output is never written to")
}

// The generic contract: a track resolves a key through the sequencer, and gets
// the object the animator bound — with no reference to the animator anywhere
// in the asking code. Driven through a Track_Ctx the way a real track is.
@(test)
test_track_resolves_key_through_sequencer :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	anim.animation_track_init()

	root := engine.transform_new("Rig")
	engine.scene_set_root(tc.scene, root)
	voice := engine.transform_new("Voice", root)
	engine.transform_add_comp(voice, .AudioSource)

	tl := engine.transform_new("Timeline", root)
	d_owned, draw := engine.transform_add_comp(tl, .PlayableDirector)
	(cast(^seq.PlayableDirector)draw).enabled = true

	_, raw := engine.transform_add_comp(root, .TimelineAnimator)
	ta := cast(^anim.TimelineAnimator)raw
	ta.enabled = true
	ta.outputs = make([dynamic]anim.Output_Binding)
	append(&ta.outputs, _output("Voice", voice))
	ta.layers = make([dynamic]anim.Animator_Layer)
	layer := anim.Animator_Layer{name = strings.clone("Base")}
	layer.states = make([dynamic]anim.Timeline_State)
	append(&layer.states, anim.Timeline_State{
		name     = strings.clone("Idle"),
		timeline = {local_id = d_owned.local_id, handle = d_owned.handle},
	})
	append(&ta.layers, layer)

	anim.timeline_animator_tick(0) // adopts the director, registering it as key-resolvable

	// What any plugin's track holds when it asks: its director's transform.
	ctx := seq.Track_Ctx{owner = tl}
	if tH, ok := seq.track_resolve_key(&ctx, "Voice"); testing.expect(t, ok, "a bound key resolves through the sequencer") {
		testing.expect_value(t, tH, voice)
	}
	_, ok := seq.track_resolve_key(&ctx, "Nobody")
	testing.expect(t, !ok, "an unbound key does not resolve")
	_, ok = seq.track_resolve_key(&ctx, "")
	testing.expect(t, !ok, "an empty key never resolves — the track falls back to its own target")

	// A director nothing adopted resolves nothing, whatever the key.
	loose := engine.transform_new("Loose", root)
	engine.transform_add_comp(loose, .PlayableDirector)
	loose_ctx := seq.Track_Ctx{owner = loose}
	_, ok = seq.track_resolve_key(&loose_ctx, "Voice")
	testing.expect(t, !ok, "an unadopted director has no driver to ask")
}
