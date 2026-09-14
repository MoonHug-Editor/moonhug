package audio_tests

// No test may open a playback device. Two reasons, and the first one is a bug
// rather than an annoyance: a device mixer is driven by its own audio callback,
// so mix.Generate pulls no frames from it, and a test that steps a clip by hand
// sees tracks that never finish. test_one_shot_lifecycle failed exactly that
// way — but only in a full run, because it needs an EARLIER test to have opened
// the device first (clip_load opens one on its own through _mixer_ensure).
// Alone it passed, which is what kept it looking like flakiness.
//
// The second reason is that it plays the fixtures out loud.
//
// @(init) rather than a call in each test: the device is claimed by whoever
// asks first, which may be a test that never mentions the mixer at all.

import "base:runtime"
import audio "moonhug:packages/audio"

@(init)
_audio_tests_force_deviceless :: proc "contextless" () {
	context = runtime.default_context()
	audio.audio_force_deviceless()
}
