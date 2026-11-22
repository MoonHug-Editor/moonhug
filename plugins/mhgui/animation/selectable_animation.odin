package mhgui_animation

// The Animation transition of a Selectable (packages/mhgui selectable.odin):
// when a Button, a Toggle or a Slider with that transition changes state, the
// Animation component on its target node plays the state of the same name:
// Normal, Highlighted, Pressed, Selected or Disabled. A name the Animation
// has no state for plays nothing. The change fades over the Selectable's
// fade_duration.
//
// This folder is what mhgui adds with the animation plugin installed. mhgui
// itself builds without it.

import "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import mhgui "moonhug:packages/mhgui"

// After mhgui's ui_tick (order -100) has set this frame's states.
@(update={order=-95})
selectable_animation_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	{
		it := engine.pool_iterator(mhgui.buttons(w))
		for c, _ in engine.pool_next(&it) do if c.enabled do _play(&c.selectable, c.owner)
	}
	{
		it := engine.pool_iterator(mhgui.toggles(w))
		for c, _ in engine.pool_next(&it) do if c.enabled do _play(&c.selectable, c.owner)
	}
	{
		it := engine.pool_iterator(mhgui.sliders(w))
		for c, _ in engine.pool_next(&it) do if c.enabled do _play(&c.selectable, c.owner)
	}
}

@(private = "file")
_play :: proc(s: ^mhgui.Selectable, owner: engine.Transform_Handle) {
	if s.transition != .Animation || s.shown == u8(s.state) + 1 do return
	if !engine.transform_active_in_hierarchy(owner) do return
	_, a := engine.transform_get_comp(mhgui.selectable_target(s, owner), anim.Animation)
	if a == nil || !a.enabled do return
	s.shown = u8(s.state) + 1
	if id, ok := anim.animation_find(a, mhgui.selectable_state_name(s.state)); ok {
		anim.animation_play_entry(a, id, max(s.colors.fade_duration, 0))
	}
}
