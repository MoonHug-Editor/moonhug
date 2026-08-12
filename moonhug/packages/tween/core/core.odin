package tween_core

// Base vocabulary for tween variants: the base struct every variant embeds,
// the tick status and the context ticks receive.
//
// A package declares its own tween variant by embedding Tween and importing
// ONLY this package (plus engine for world access) — never
// moonhug:packages/tween: the generated TweenUnion there imports every
// variant package, so a variant package importing tween is a cycle.
// tween_gen finds the variant, adds it to the union and emits adapters for
// its tick_<T> / tween_free_<T> procs (which take ^<T>, the concrete type).
// Foreign variants are leaves — children fields need TweenUnion, which only
// packages/tween can name. See moonhug/packages/tween/nodes for the
// reference variants.

import core "moonhug:engine/core"

Status :: enum {
	Pending,
	Running,
	Done,
}

// Hierarchical Task
@(typ_guid={guid="aecaf150-0418-4fed-81a3-708f68ccaa8b"})
Tween :: struct {
	skip:     bool,
	is_await: bool,
	delay:    f32,
	subject:  core.Ref `ref:"Transform"`,

	// runtime only fields:
	delay_elapsed: f32 `json:"-"`,
	status:        Status `json:"-"`,
}

TweenContext :: struct {
	subject: core.Transform_Handle `json:"-"`,
}

tween_has_delay :: proc(base: ^Tween, delta_time: f32) -> bool {
	if base.delay_elapsed < base.delay {
		base.delay_elapsed += delta_time
		return true
	}
	return false
}
