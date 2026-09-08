package sequencer_tweens

// The built-in clip-tween variants. A variant is a @(typ_guid) struct
// embedding core.Clip_Tween plus one evaluate_<Name>(self, t, ctx) proc —
// pose as a pure function of clip-normalized t in [0..1]. To-style variants
// capture `from` on their first evaluation (the captured flag lives in the
// base, so the track restores and clears it generically).
//
// Naming: abstract first, concrete later — Tween<Aspect><Space><Detail>.
// Names must not collide with packages/tween's node types (one global
// @(typ_guid) name space): TweenMoveLocalTo here vs TweenMoveToLocal there.
//
// This package sits BELOW the union on purpose: it imports sequencer/core
// and engine only, exactly like a plugin's tween package would, so the
// built-ins prove the same path plugins take. (TweenFadeTo belongs to the
// sprites package — color lives on SpriteRenderer — and joins the union
// once the generator owns the import list.)

import "core:math/linalg"
import "moonhug:engine"
import core "moonhug:packages/sequencer/core"

// The subject a variant poses: its own target when set, else the track's.
@(private)
_subject :: proc(own: engine.Ref_Local, ctx: ^core.Tween_Ctx) -> ^engine.Transform {
	h := own.handle
	if h.type_key != .Transform do h = ctx.target.handle
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, h) do return nil
	return engine.pool_get(&w.transforms, h)
}

@(typ_guid={guid = "9c405478-1d6d-4b40-b90f-0b13a65dd8b9"})
TweenNone :: struct {
	using base: core.Clip_Tween `inline:""`,
}

// Local position from an EXPLICIT pair — fully stateless, nothing captured.
@(typ_guid={guid = "705f0b28-2818-41e7-938c-9404ad1fe238"})
TweenMoveLocalFromTo :: struct {
	using base: core.Clip_Tween `inline:""`,
	target:     engine.Ref_Local `ref:"Transform"`,
	from:       [3]f32,
	to:         [3]f32,
}

evaluate_TweenMoveLocalFromTo :: proc(s: ^TweenMoveLocalFromTo, t: f32, ctx: ^core.Tween_Ctx) {
	tr := _subject(s.target, ctx)
	if tr == nil do return
	tr.position = s.from + (s.to - s.from) * t
}

// Local position from WHEREVER IT WAS at the span's start.
@(typ_guid={guid = "39f6ed5d-4ba2-4673-a1a9-246668f2868a"})
TweenMoveLocalTo :: struct {
	using base: core.Clip_Tween `inline:""`,
	target:     engine.Ref_Local `ref:"Transform"`,
	to:         [3]f32,

	from: [3]f32 `json:"-" inspect:"-"`,
}

evaluate_TweenMoveLocalTo :: proc(s: ^TweenMoveLocalTo, t: f32, ctx: ^core.Tween_Ctx) {
	tr := _subject(s.target, ctx)
	if tr == nil do return
	if !s.captured {
		s.captured = true
		s.from = tr.position
	}
	tr.position = s.from + (s.to - s.from) * t
}

@(typ_guid={guid = "e0f71a0e-7048-4e60-be2f-4f7907c50348"})
TweenScaleLocalTo :: struct {
	using base: core.Clip_Tween `inline:""`,
	target:     engine.Ref_Local `ref:"Transform"`,
	to:         [3]f32,

	from: [3]f32 `json:"-" inspect:"-"`,
}

evaluate_TweenScaleLocalTo :: proc(s: ^TweenScaleLocalTo, t: f32, ctx: ^core.Tween_Ctx) {
	tr := _subject(s.target, ctx)
	if tr == nil do return
	if !s.captured {
		s.captured = true
		s.from = tr.scale
	}
	tr.scale = s.from + (s.to - s.from) * t
}

@(typ_guid={guid = "096bd099-97e3-45b7-a374-f0180d06d795"})
TweenRotateLocalTo :: struct {
	using base: core.Clip_Tween `inline:""`,
	target:     engine.Ref_Local `ref:"Transform"`,
	to:         [4]f32 `inspect:"" decor:euler()`,

	from: [4]f32 `json:"-" inspect:"-"`,
}

evaluate_TweenRotateLocalTo :: proc(s: ^TweenRotateLocalTo, t: f32, ctx: ^core.Tween_Ctx) {
	tr := _subject(s.target, ctx)
	if tr == nil do return
	if !s.captured {
		s.captured = true
		s.from = tr.rotation
	}
	tr.rotation = engine.quat_from_native(linalg.quaternion_slerp(
		engine.quat_to_native(s.from), engine.quat_to_native(s.to), t))
}
