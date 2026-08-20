package audio

// Unity-literal AudioListener: the ear. Spatial sources attenuate and pan
// relative to the first enabled listener's world transform (usually the
// camera). No fields — the transform is the data.

import engine "moonhug:engine"

@(component={menu="Audio/AudioListener"})
@(typ_guid={guid="14a605d8-3796-467b-8f9f-76dadf3baa73"})
AudioListener :: struct {
	using base: engine.CompData `inspect:"-"`,
}

reset_AudioListener :: proc(comp: ^AudioListener) {
}
