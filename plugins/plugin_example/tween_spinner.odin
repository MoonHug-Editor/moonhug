package plugin_example

// A tween node declared outside the tween package — the working example of
// open tween extension (plugins/tween/docs/concepts/AuthoredAndLive.md). A variant package imports tween
// directly and registers its node type on the SerializationInit phase. No
// codegen, no import restrictions — composites with children would work the
// same way (`children: [dynamic]tween.Node_Handle` with json:"-").

import engine "moonhug:packages/engine"
import log "moonhug:libs/log"
import tween "moonhug:packages/tween"

// Moves the subject's Spinner `speed` to `speed` over `duration` — a tween
// targeting this package's own component.
@(typ_guid={guid="e90cff1c-4f9d-4f0e-a727-08dbd42e43f2"})
TweenSpinnerSpeed :: struct {
	using base: tween.Tween `inline:""`,
	using anim: tween.Tween_Anim `inline:""`,
	speed:    [3]f32,
	duration: f32,

	from: [3]f32 `json:"-"`,
}

// Tween_Anim owns its curve's keys.
type_cleanup_TweenSpinnerSpeed :: proc(self: ^TweenSpinnerSpeed) {
	tween.type_cleanup_Tween_Anim(&self.anim)
	self^ = {}
}

@(phase={key=SerializationInit, order=2})
spinner_tween_nodes_init :: proc() {
	tween.register_tween(TweenSpinnerSpeed, begin_TweenSpinnerSpeed, apply_TweenSpinnerSpeed)
}

// Captures the speed the node starts from. No Spinner on the subject ends the node.
begin_TweenSpinnerSpeed :: proc(self: ^TweenSpinnerSpeed, ctx: tween.TweenContext) -> bool {
	_, spinner := get_comp(tween.subject_of(&self.base, ctx), Spinner)
	if spinner == nil {
		// An authoring mistake, not a runtime condition — say so once instead
		// of completing silently.
		@(static) warned := false
		if !warned {
			warned = true
			name := "?"
			w := engine.ctx_world()
			if t := engine.pool_get(&w.transforms, engine.Handle(tween.subject_of(&self.base, ctx))); t != nil do name = t.name
			log.errorf("TweenSpinnerSpeed: subject '%s' has no Spinner component — tween does nothing", name)
		}
		return false
	}
	self.from = spinner.speed
	return true
}

apply_TweenSpinnerSpeed :: proc(self: ^TweenSpinnerSpeed, t: f32, ctx: tween.TweenContext) {
	_, spinner := get_comp(tween.subject_of(&self.base, ctx), Spinner)
	if spinner == nil do return
	spinner.speed = self.from + (self.speed - self.from) * t
}
