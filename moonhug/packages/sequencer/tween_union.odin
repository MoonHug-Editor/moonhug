package sequencer

// TweenUnion — every clip-tween variant a clip can carry, and the evaluate
// dispatch over them. HAND-WRITTEN for now; this file is the future
// generated artifact (a tween_gen scanning packages/ for @(typ_guid) clip
// tweens, the same shape as script_union.odin). Until then, a plugin adds a
// variant by:
//
//   1. shipping a package that imports moonhug:packages/sequencer/core
//      (never the sequencer itself — variants live BELOW the union),
//      declaring a @(typ_guid) struct embedding core.Clip_Tween with an
//      evaluate_<Name> proc, and destroy_<Name> when it owns heap
//   2. adding the import and the matching cases in this file
//
// Everything else is generic: serialization keys variants by type guid,
// _resolve_refs_in_value walks into the active variant so Ref_Local fields
// rebind on load, and the inspector's union drawer offers the variants by
// name. Runtime capture state stays out of files via json:"-".

import "core:encoding/json"
import "moonhug:engine"
import serialization "moonhug:engine/serialization"
import core "moonhug:packages/sequencer/core"
import tweens "moonhug:packages/sequencer/tweens"

TweenUnion :: union {
	tweens.TweenMoveLocalFromTo,
	tweens.TweenMoveLocalTo,
	tweens.TweenScaleLocalTo,
	tweens.TweenRotateLocalTo,
}

// Poses the active variant at clip-normalized t in [0..1]. Pure given the
// captured start pose — the same call serves Play, scrubbing and the
// edit-mode preview, which is what makes clip tweens edit-mode safe.
tween_evaluate :: proc(u: ^TweenUnion, t: f32, ctx: ^core.Tween_Ctx) {
	switch &v in u {
	case tweens.TweenMoveLocalFromTo:
		tweens.evaluate_TweenMoveLocalFromTo(&v, t, ctx)
	case tweens.TweenMoveLocalTo:
		tweens.evaluate_TweenMoveLocalTo(&v, t, ctx)
	case tweens.TweenScaleLocalTo:
		tweens.evaluate_TweenScaleLocalTo(&v, t, ctx)
	case tweens.TweenRotateLocalTo:
		tweens.evaluate_TweenRotateLocalTo(&v, t, ctx)
	}
}

// The embedded Clip_Tween base of the active variant, nil for a nil union —
// what lets the track test and clear `captured` without per-variant code.
tween_base :: proc(u: ^TweenUnion) -> ^core.Clip_Tween {
	switch &v in u {
	case tweens.TweenMoveLocalFromTo:
		return &v.base
	case tweens.TweenMoveLocalTo:
		return &v.base
	case tweens.TweenScaleLocalTo:
		return &v.base
	case tweens.TweenRotateLocalTo:
		return &v.base
	}
	return nil
}

// Frees whatever heap the active variant owns and clears the union. No
// built-in owns any today; the case list keeps the contract visible for
// variants that will.
tween_destroy :: proc(u: ^TweenUnion) {
	u^ = nil
}

@(phase={key=SerializationInit, order=2})
tween_union_serialization_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	// Guid-keyed union persistence (engine/serialization) plus the union's
	// pointer type for undo capture of [dynamic]TweenUnion fields — silently
	// no-ops without it (docs/Undo.md).
	json.register_user_marshaler(TweenUnion, serialization.union_marshal)
	json.register_user_unmarshaler(TweenUnion, serialization.union_unmarshal)
	engine.register_pointer_type(TweenUnion)
}
