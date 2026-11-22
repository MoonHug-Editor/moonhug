package mhgui

// Toggle: a control that is on or off. A click flips it, and so does the
// submit key while it is selected. `graphic` names the node that shows only
// while it is on, the check mark. Toggles that name the same ToggleGroup are
// a set of which one is on at a time.
//
// It is a Selectable (selectable.odin): it tints its target graphic with the
// pointer, as a Button does.

import "moonhug:packages/engine"

@(component={menu="UI/Toggle"})
@(typ_guid={guid = "cd4cc473-9feb-4b44-9bd4-cc5e3f5164ce"})
Toggle :: struct {
	using base:       engine.CompData `inspect:"-"`,
	using selectable: Selectable `inline:""`,
	is_on:   bool,
	graphic: engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node that shows only while the toggle is on: the check mark.")`,
	group:   engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the ToggleGroup this toggle belongs to. Empty stands alone.")`,
	// Runtime state, never saved.
	changed: bool `json:"-" inspect:"-"`, // flipped this frame
}

// Makes the toggles that name it a set: turning one on turns the others off.
@(component={menu="UI/ToggleGroup"})
@(typ_guid={guid = "e6261cce-a4e8-4564-9677-6112f984a7c4"})
ToggleGroup :: struct {
	using base:       engine.CompData `inspect:"-"`,
	allow_switch_off: bool `decor:tooltip(desc="A click on the toggle that is on turns it off, leaving none on. Off, one stays on.")`,
}

type_reset_Toggle :: proc(t: ^Toggle) {
	selectable_reset(&t.selectable)
}

// True on the frame the toggle flipped. Read after ui_tick (any @(update)
// at order 0 or later).
toggle_changed :: proc(t: ^Toggle) -> bool {
	return t.changed
}

// Turns the toggle on or off, as a click does: in a group, turning it on
// turns the others off, and turning the on one off is refused unless the
// group allows none on. `changed` is set when it flipped.
toggle_set :: proc(t: ^Toggle, on: bool) {
	if t.is_on == on do return
	group_tH := engine.Transform_Handle(t.group.handle)
	_, group := engine.transform_get_comp(group_tH, ToggleGroup)
	if group != nil && group.enabled {
		if !on && !group.allow_switch_off do return
		if on {
			w := engine.ctx_world()
			it := engine.pool_iterator(toggles(w))
			for other, _ in engine.pool_next(&it) {
				if other == t || !other.is_on || engine.Transform_Handle(other.group.handle) != group_tH do continue
				other.is_on = false
				other.changed = true
				_toggle_show(other)
			}
		}
	}
	t.is_on = on
	t.changed = true
	_toggle_show(t)
}

// The check mark shows while the toggle is on.
@(private = "file")
_toggle_show :: proc(t: ^Toggle) {
	_, cr := engine.transform_get_comp(engine.Transform_Handle(t.graphic.handle), engine.CanvasRenderer)
	if cr != nil do cr.enabled = t.is_on
}

@(comp_on_pointer_ui={component=Toggle})
comp_on_pointer_ui_Toggle :: proc(t: ^Toggle, ev: ^engine.UI_Pointer_Event) {
	selectable_pointer(&t.selectable, ev)
	if ev.kind == .Click && ev.button == .Left && t.interactable {
		toggle_set(t, !t.is_on)
		ev.used = true
	}
}

// ui_tick: last frame's changes are over.
toggles_frame_begin :: proc() {
	it := engine.pool_iterator(toggles(engine.ctx_world()))
	for t, _ in engine.pool_next(&it) do t.changed = false
}

// ui_tick: the submit key flips the selected Toggle, then every Toggle's look.
toggles_update :: proc(selected: engine.Transform_Handle, submit, submit_down: bool, dt: f32) {
	it := engine.pool_iterator(toggles(engine.ctx_world()))
	for t, _ in engine.pool_next(&it) {
		live := t.enabled && engine.transform_active_in_hierarchy(t.owner)
		chosen := live && selected == t.owner
		if live && t.interactable && submit && chosen do toggle_set(t, !t.is_on)
		// The mark follows is_on, set by a click, a key or code.
		if live do _toggle_show(t)
		selectable_update(&t.selectable, t.owner, live, chosen, submit_down, dt)
	}
}
