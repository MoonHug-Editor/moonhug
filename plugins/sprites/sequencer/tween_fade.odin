package sprites_sequencer

// A clip tween owned by the sprites plugin, because the thing it poses is its
// component (plugins/sequencer/docs/Sequencer.md "Tweens"). It imports only sequencer/core —
// never the sequencer — and tween_gen picks it up by the embedded Clip_Tween
// base, adding it to TweenUnion on the next prebuild. That is the whole
// plugin contract: no registration call, no edit to the sequencer. The
// folder compiles only with the sequencer installed (docs/core/Plugins.md).

import "moonhug:packages/engine"
import seq_core "moonhug:packages/sequencer/core"
import sprites "moonhug:packages/sprites"

// Fades the bound SpriteRenderer's alpha to `to`, keeping RGB. The start
// alpha is captured per the base's Capture_Mode.
@(typ_guid={guid = "77d750ed-4d7e-47b9-b8af-3e5c0cf69e02"})
TweenFadeTo :: struct {
	using base: seq_core.Clip_Tween `inline:""`,
	target:     engine.Ref_Local `ref:"SpriteRenderer"`,
	to:         f32,

	from: f32 `json:"-" inspect:"-"`,
}

evaluate_TweenFadeTo :: proc(s: ^TweenFadeTo, t: f32, ctx: ^seq_core.Tween_Ctx) {
	h := s.target.handle
	if h.type_key != .SpriteRenderer do h = ctx.target.handle
	if h.type_key != .SpriteRenderer do return
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, h) do return
	sr := cast(^sprites.SpriteRenderer)engine.world_pool_get(w, h)
	if sr == nil do return
	if !s.captured {
		s.captured = true
		s.from = sr.color.a
	}
	sr.color.a = s.from + (s.to - s.from) * t
}
