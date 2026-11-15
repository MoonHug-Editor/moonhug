package audio_tween_tests

// The audio plugin's one-line tweens (audio/tween).

import "core:testing"
import audio "moonhug:packages/audio"
import audio_tween "moonhug:packages/audio/tween"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"
import common "moonhug:tests/common"

@(test)
test_audio_volume_and_pitch :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	tween.tween_init()
	defer tween.stop_all()

	owner := engine.transform_new("Music")
	_, raw := engine.transform_add_comp(owner, .AudioSource)
	source := cast(^audio.AudioSource)raw
	source.volume = 1
	source.pitch = 1

	audio_tween.volume(owner, 0, 1)
	audio_tween.pitch(owner, 2, 1)
	for _ in 0 ..< 32 do tween.tick_all(1.0 / 64.0)
	testing.expect(t, abs(source.volume - 0.5) < 1e-4)
	testing.expect(t, abs(source.pitch - 1.5) < 1e-4)
	for _ in 0 ..< 33 do tween.tick_all(1.0 / 64.0)
	testing.expect_value(t, source.volume, f32(0))
	testing.expect_value(t, source.pitch, f32(2))
}
