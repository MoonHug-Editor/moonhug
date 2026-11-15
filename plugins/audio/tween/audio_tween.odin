package audio_tween

// One-line tweens for the audio plugin's component, owned here because the
// thing they animate is its AudioSource. The folder compiles only with the
// tween plugin installed (docs/core/Plugins.md).
//
//   import audio_tween "moonhug:packages/audio/tween"
//
//   audio_tween.volume(music, 0, 2)            // fade out over two seconds
//   audio_tween.pitch(engine_sound, 1.5, 0.3)

import audio "moonhug:packages/audio"
import "moonhug:packages/engine"
import tween "moonhug:packages/tween"

// An AudioSource's volume from what it is to `to`.
volume :: proc(target: engine.Transform_Handle, to: f32, timing: tween.Timing, ease := tween.Ease.Linear, opt := tween.Options{}) -> tween.Handle {
	return tween.field(target, _volume_of, to, timing, ease, opt)
}

// An AudioSource's pitch: its playback frequency ratio, 1 as authored.
pitch :: proc(target: engine.Transform_Handle, to: f32, timing: tween.Timing, ease := tween.Ease.Linear, opt := tween.Options{}) -> tween.Handle {
	return tween.field(target, _pitch_of, to, timing, ease, opt)
}

@(private = "file")
_volume_of :: proc(target: engine.Transform_Handle) -> rawptr {
	_, source := audio.get_comp(target, audio.AudioSource)
	return &source.volume if source != nil else nil
}

@(private = "file")
_pitch_of :: proc(target: engine.Transform_Handle) -> rawptr {
	_, source := audio.get_comp(target, audio.AudioSource)
	return &source.pitch if source != nil else nil
}
