package sequencer

// The built-in track kinds' components. Each is the DISCRIMINATOR for its
// kind (the registry keys on TypeKey) and owns whatever that kind needs —
// targets carry a `ref:` tag so the inspector's picker filters itself, and a
// kind that needs no target simply has no field.

import "moonhug:engine"

// Activation: the bound transform is active while a clip covers the time.
@(component)
@(typ_guid={guid = "42ef8665-a34a-457c-9c56-e6d89ce4aad0"})
ActivationTrack :: struct {
	using base: engine.CompData `inspect:"-"`,

	target: engine.Ref_Local `ref:"Transform"`,
}

@(component)
@(typ_guid={guid = "5cb239de-5d09-4070-82de-a27a8c5f4427"})
ActivationClip :: struct {
	using base: engine.CompData `inspect:"-"`,
}

// Markers: zero-duration clips fire timeline_marker_hook on crossing.
@(component)
@(typ_guid={guid = "a73d7ccb-e92c-4dad-9a99-0b425d37d6a0"})
MarkerTrack :: struct {
	using base: engine.CompData `inspect:"-"`,

	target: engine.Ref_Local `ref:"Transform"`,
}

@(component)
@(typ_guid={guid = "6f85f97f-fb31-48ca-9071-acce0827173a"})
MarkerClip :: struct {
	using base: engine.CompData `inspect:"-"`,
}

// Control: each clip plays the nested timeline under its node. The target
// is the clip's own child subtree, so there is no target field.
@(component)
@(typ_guid={guid = "2edca93b-16a6-4c12-97ec-29e404886dab"})
ControlTrack :: struct {
	using base: engine.CompData `inspect:"-"`,
}

@(component)
@(typ_guid={guid = "e33bf06b-054a-4cde-ad51-ec20cbfd9bae"})
ControlClip :: struct {
	using base: engine.CompData `inspect:"-"`,
}
