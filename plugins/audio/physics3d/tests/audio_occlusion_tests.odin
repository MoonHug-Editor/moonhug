package audio_physics3d_tests

// AudioOcclusion (audio/physics3d): a collider between the listener and the
// source muffles the source. The listener's and the source's own colliders
// never do, nor a collider on a layer the component leaves out.

import "core:testing"
import "moonhug:packages/engine"
import audio "moonhug:packages/audio"
import physics3d "moonhug:packages/physics3d"
import common "moonhug:tests/common"
import ap ".."

@(private = "file")
_object :: proc(name: string, pos: [3]f32, layers: u32 = 1) -> engine.Transform_Handle {
	tH := engine.transform_new(name)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = pos
	_, raw := engine.transform_add_comp(tH, .BoxCollider)
	box := cast(^physics3d.BoxCollider)raw
	box.enabled = true
	box.size = {1, 1, 1}
	box.density = 1
	box.layers = layers
	return tH
}

// Steps the listener and the occlusion for `seconds`.
@(private = "file")
_run :: proc(seconds: f32) {
	for _ in 0 ..< int(seconds * 60) {
		audio.audio_update(1.0 / 60)
		ap.audio_occlusion_update(1.0 / 60)
	}
}

@(test)
test_a_wall_between_listener_and_source_muffles_it :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	audio.mixer_init_headless()

	// The listener and the source each carry a collider of their own.
	ear := _object("Ear", {0, 0, 0})
	_, _ = engine.transform_add_comp(ear, .AudioListener)
	speaker := _object("Speaker", {10, 0, 0})
	_, src_raw := engine.transform_add_comp(speaker, .AudioSource)
	src := cast(^audio.AudioSource)src_raw
	src.play_on_awake = false
	_, occ_raw := engine.transform_add_comp(speaker, .AudioOcclusion)
	occ := cast(^ap.AudioOcclusion)occ_raw
	physics3d.physics_step(1.0 / 60)

	_run(0.5)
	testing.expectf(t, occ.amount == 0, "nothing between them: clear, got %v", occ.amount)
	testing.expect(t, !ap.audio_occluded({}, ear, speaker, ~u32(0)), "their own colliders do not block")

	// A wall in between: blocked, reached at `speed` (6 a second).
	wall := _object("Wall", {5, 0, 0}, layers = 1 << 2)
	physics3d.physics_step(1.0 / 60)
	_run(0.1)
	testing.expectf(t, occ.amount > 0.4 && occ.amount < 0.8, "a tenth of a second later, partly muffled: %v", occ.amount)
	_run(0.3)
	testing.expect_value(t, occ.amount, 1)
	testing.expect_value(t, src.occlusion.amount, 1)
	testing.expect_value(t, src.occlusion.cutoff, 800)
	testing.expect(t, src.occlusion.frame == audio.audio_frame(), "set this frame")

	// Left out of the layers, the wall no longer blocks.
	occ.layers = 1 << 0
	_run(0.5)
	testing.expect_value(t, occ.amount, 0)
	_ = wall
}
