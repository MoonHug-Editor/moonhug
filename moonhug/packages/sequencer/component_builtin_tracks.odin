package sequencer

// The built-in track kinds' components. Each is the DISCRIMINATOR for its
// kind (the registry keys on TypeKey) and owns whatever that kind needs —
// targets carry a `ref:` tag so the inspector's picker filters itself, and a
// kind that needs no target simply has no field.

import "moonhug:engine"

// Activation: the bound transform is active while a clip covers the time.
@(component)
@(typ_guid={guid = "42ef8665-a34a-457c-9c56-e6d89ce4aad0"})
TrackActivation :: struct {
	using base: engine.CompData `inspect:"-"`,

	target: engine.Ref_Local `ref:"Transform"`,
}

@(component)
@(typ_guid={guid = "5cb239de-5d09-4070-82de-a27a8c5f4427"})
ClipActivation :: struct {
	using base: engine.CompData `inspect:"-"`,
}

// Control: each clip plays the nested timeline under its node. The target
// is the clip's own child subtree, so there is no target field.
@(component)
@(typ_guid={guid = "2edca93b-16a6-4c12-97ec-29e404886dab"})
TrackControl :: struct {
	using base: engine.CompData `inspect:"-"`,
}

@(component)
@(typ_guid={guid = "e33bf06b-054a-4cde-ad51-ec20cbfd9bae"})
ClipControl :: struct {
	using base: engine.CompData `inspect:"-"`,
}
