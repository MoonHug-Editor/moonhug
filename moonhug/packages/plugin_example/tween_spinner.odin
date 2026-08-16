package plugin_example

// A tween variant declared OUTSIDE the tween package — the working example
// of the variant triangle (docs/Tweens.md). This package imports ONLY
// moonhug:packages/tween/core (never tween: the generated TweenUnion there
// imports this package, so importing tween back is a cycle). tween_gen finds
// the struct by its `base` field, adds it to the union and emits the
// adapter for tick_TweenSpinnerSpeed.

import engine "moonhug:engine"
import log "moonhug:engine/log"
import tween_core "moonhug:packages/tween/core"

// Eases the subject's Spinner `speed` toward `speed` over `duration` —
// a tween targeting this package's own component.
@(typ_guid={guid="e90cff1c-4f9d-4f0e-a727-08dbd42e43f2"})
TweenSpinnerSpeed :: struct {
	using base: tween_core.Tween `inline:""`,
	speed:    [3]f32,
	duration: f32,

	elapsed: f32 `json:"-"`,
	from:    [3]f32 `json:"-"`,
}

tick_TweenSpinnerSpeed :: proc(self: ^TweenSpinnerSpeed, delta_time: f32, ctx: tween_core.TweenContext) -> tween_core.Status {
	if tween_core.tween_has_delay(&self.base, delta_time) do return .Running

	_, spinner := get_comp(ctx.subject, Spinner)
	if spinner == nil {
		// An authoring mistake, not a runtime condition — say so once instead
		// of completing silently.
		@(static) warned := false
		if !warned {
			warned = true
			name := "?"
			w := engine.ctx_world()
			if t := engine.pool_get(&w.transforms, engine.Handle(ctx.subject)); t != nil do name = t.name
			log.errorf("TweenSpinnerSpeed: subject '%s' has no Spinner component — tween does nothing", name)
		}
		return .Done
	}
	if self.duration == 0 {
		spinner.speed = self.speed
		return .Done
	}
	if self.elapsed == 0 do self.from = spinner.speed
	self.elapsed += delta_time
	t := clamp(self.elapsed / self.duration, 0, 1)
	spinner.speed = self.from + (self.speed - self.from) * t
	return .Done if t >= 1 else .Running
}
