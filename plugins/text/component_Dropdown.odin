package text

// Dropdown: a control that shows one of a list of options and opens the list
// to pick another. The usual tree, which GameObject, UI, Dropdown makes:
//
//   Dropdown       the background graphic, Dropdown
//   ├── Label      a Text that shows the chosen option (`caption`)
//   └── Template   the list, inactive (`template`)
//       └── Item       DropdownItem: one row, with its Text and its check mark
//
// - A click, or the submit key while it is selected, opens the list: the
//   Dropdown copies the Template, makes a copy of the Item for each option,
//   and shows the copy over everything else on its canvas (z_index).
// - A click on a row, or the submit key on the selected row, picks its
//   option and closes the list. `changed` is set when the value changed.
// - A click anywhere else, Escape, or the selection moving off the list
//   closes it and picks nothing. While it is open a node that takes the
//   pointer covers the canvas under the list, so the click that closes it
//   presses nothing else.
// - The Template is an ordinary subtree: its look, a LayoutGroup that stacks
//   the rows, a ScrollRect for a long list are all the scene's. The Dropdown
//   only needs one DropdownItem somewhere under it.
//
// Dropdown and DropdownItem are Selectables (mhgui selectable.odin).

import "base:runtime"
import "core:strings"
import "moonhug:packages/engine"
import "moonhug:libs/input"
import "moonhug:libs/time"
import mhgui "moonhug:packages/mhgui"

// What an open list's z_index is raised by, and its blocker's one less: over
// everything else on the canvas.
DROPDOWN_Z :: 1000

@(component={menu="UI/Dropdown"})
@(typ_guid={guid = "2c7e1d94-58b3-4a6f-9d21-7e4b0a3c6f15"})
Dropdown :: struct {
	using base:       engine.CompData `inspect:"-"`,
	using selectable: mhgui.Selectable `inline:""`,
	options:          [dynamic]string `decor:tooltip(desc="The choices, in the order the list shows them.")`,
	value:            i32 `decor:min(0) decor:tooltip(desc="The chosen option, counted from 0.")`,
	caption:          engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the Text that shows the chosen option.")`,
	template:         engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The list: an inactive node with one DropdownItem under it. The open list is a copy of it.")`,
	// Runtime state, never saved.
	changed: bool `json:"-" inspect:"-"`, // the value changed this frame
	clicked: bool `json:"-" inspect:"-"`,
	list:    engine.Transform_Handle `json:"-" inspect:"-"`, // the open list, {} while closed
	blocker: engine.Transform_Handle `json:"-" inspect:"-"`,
}

// One row of a Dropdown's list. The Template holds one, and the open list
// has a copy for each option.
@(component={menu="UI/DropdownItem"})
@(typ_guid={guid = "8f3a6c50-1e92-47d8-b6a4-0c5d9e2f7b38"})
DropdownItem :: struct {
	using base:       engine.CompData `inspect:"-"`,
	using selectable: mhgui.Selectable `inline:""`,
	label:            engine.Ref_Local `ref:"Transform" decor:tooltip(desc="The node with the Text that shows the row's option.")`,
	checkmark:        engine.Ref_Local `ref:"Transform" decor:tooltip(desc="A node that is active only on the row of the chosen option.")`,
	// Runtime state, never saved.
	index:    i32 `json:"-" inspect:"-"`, // the row's option, -1 for the node that covers the canvas
	dropdown: engine.Transform_Handle `json:"-" inspect:"-"`,
	clicked:  bool `json:"-" inspect:"-"`,
}

type_reset_Dropdown :: proc(d: ^Dropdown) {
	type_cleanup_Dropdown(d)
	mhgui.selectable_reset(&d.selectable)
}

type_cleanup_Dropdown :: proc(d: ^Dropdown) {
	for o in d.options do if o != "" do delete(o)
	delete(d.options)
	d.options = nil
}

type_reset_DropdownItem :: proc(item: ^DropdownItem) {
	mhgui.selectable_reset(&item.selectable)
}

@(init)
_dropdown_register :: proc "contextless" () {
	context = runtime.default_context()
	mhgui.selectable_register(proc(tH: engine.Transform_Handle) -> (^mhgui.Selectable, bool) {
		if _, d := engine.transform_get_comp(tH, Dropdown); d != nil do return &d.selectable, d.enabled
		if _, item := engine.transform_get_comp(tH, DropdownItem); item != nil do return &item.selectable, item.enabled
		return nil, false
	})
}

// Makes `s` the string a Text shows.
text_set :: proc(tx: ^Text, s: string) {
	if tx == nil || tx.text == s do return
	if tx.text != "" do delete(tx.text)
	tx.text = strings.clone(s) if s != "" else ""
}

// --- From code ---------------------------------------------------------------------

// True on the frame the value changed, by a pick or by dropdown_set_value.
// Read after the dropdown's update (any @(update) at order 0 or later).
dropdown_changed :: proc(d: ^Dropdown) -> bool {
	return d.changed
}

// The chosen option's string, "" with no options.
dropdown_option :: proc(d: ^Dropdown) -> string {
	if d.value < 0 || int(d.value) >= len(d.options) do return ""
	return d.options[d.value]
}

// Chooses option `value`, kept inside the list. `changed` is set when it is
// another one.
dropdown_set_value :: proc(d: ^Dropdown, value: int) {
	v := i32(clamp(value, 0, max(len(d.options) - 1, 0)))
	if v == d.value do return
	d.value = v
	d.changed = true
}

// Replaces the options. The value stays, kept inside the new list.
dropdown_set_options :: proc(d: ^Dropdown, options: []string) {
	for o in d.options do if o != "" do delete(o)
	clear(&d.options)
	for o in options do append(&d.options, strings.clone(o) if o != "" else "")
	d.value = i32(clamp(int(d.value), 0, max(len(d.options) - 1, 0)))
}

dropdown_is_open :: proc(d: ^Dropdown) -> bool {
	return d.list != {}
}

// Opens the list: a copy of the Template with a row for each option, over
// everything else on the canvas.
dropdown_show :: proc(d: ^Dropdown) {
	if d.list != {} do return
	template := engine.Transform_Handle(d.template.handle)
	canvas := engine.canvas_of(d.owner)
	if template == {} || canvas == {} do return
	list := engine.scene_duplicate_subtree(template)
	if list == {} do return
	w := engine.ctx_world()
	// The row to copy: the first DropdownItem under the list.
	first: ^DropdownItem
	{
		it := engine.pool_iterator(dropdown_items(w))
		for item, _ in engine.pool_next(&it) {
			if _under(item.owner, list) {
				first = item
				break
			}
		}
	}
	if first == nil {
		engine.transform_destroy_later(list)
		return
	}
	rows := make([dynamic]engine.Transform_Handle, context.temp_allocator)
	append(&rows, first.owner)
	for _ in 1 ..< len(d.options) {
		if row := engine.scene_duplicate_subtree(rows[0]); row != {} do append(&rows, row)
	}
	selected := rows[0]
	for row, i in rows {
		_, item := engine.transform_get_comp(row, DropdownItem)
		if item == nil do continue
		item.index = i32(i)
		item.dropdown = d.owner
		item.clicked = false
		if i < len(d.options) {
			_, label := engine.transform_get_comp(engine.Transform_Handle(item.label.handle), Text)
			text_set(label, d.options[i])
		}
		if mark := engine.Transform_Handle(item.checkmark.handle); mark != {} {
			engine.transform_set_active(mark, i32(i) == d.value)
		}
		if i32(i) == d.value do selected = row
	}
	// No options: the list opens empty.
	if len(d.options) == 0 do engine.transform_set_active(rows[0], false)
	if _, rt := engine.transform_get_comp(list, engine.RectTransform); rt != nil do rt.z_index += DROPDOWN_Z
	engine.transform_set_active(list, true)

	// A node over the whole canvas, under the list: a press outside the list
	// lands on it and closes the list.
	blocker := engine.transform_new("Dropdown Blocker", canvas)
	if _, ptr := engine.transform_add_comp(blocker, .RectTransform); ptr != nil {
		rt := cast(^engine.RectTransform)ptr
		engine.type_reset_RectTransform(rt)
		rt.enabled = true
		rt.anchor_min, rt.anchor_max = {0, 0}, {1, 1}
		rt.size_delta = {0, 0}
		rt.z_index = DROPDOWN_Z - 1
	}
	if _, ptr := engine.transform_add_comp(blocker, .HitArea); ptr != nil do (cast(^mhgui.HitArea)ptr).enabled = true
	if _, ptr := engine.transform_add_comp(blocker, .DropdownItem); ptr != nil {
		item := cast(^DropdownItem)ptr
		type_reset_DropdownItem(item)
		item.enabled = true
		item.transition = .None
		item.navigation.mode = .None
		item.index = -1
		item.dropdown = d.owner
	}
	d.list, d.blocker = list, blocker
	if len(d.options) > 0 do mhgui.ui_set_selected(selected)
}

// Closes the list. The Dropdown becomes the selected node again when the
// selection was on the list.
dropdown_hide :: proc(d: ^Dropdown) {
	if d.list == {} do return
	selected := mhgui.ui_selected()
	if selected == d.blocker || _under(selected, d.list) do mhgui.ui_set_selected(d.owner)
	engine.transform_destroy_later(d.list)
	engine.transform_destroy_later(d.blocker)
	d.list, d.blocker = {}, {}
}

// Whether `tH` is `root` or a node under it.
@(private = "file")
_under :: proc(tH, root: engine.Transform_Handle) -> bool {
	if tH == {} || root == {} do return false
	w := engine.ctx_world()
	at := tH
	for n := 0; at != {} && n < 4096; n += 1 {
		if at == root do return true
		t := engine.pool_get(&w.transforms, engine.Handle(at))
		if t == nil do return false
		at = engine.Transform_Handle(t.parent.handle)
	}
	return false
}

// --- Pointer -----------------------------------------------------------------------

@(comp_on_pointer_ui={component=Dropdown})
comp_on_pointer_ui_Dropdown :: proc(d: ^Dropdown, ev: ^mhgui.UI_Pointer_Event) {
	mhgui.selectable_pointer(&d.selectable, ev)
	if ev.kind == .Click && ev.button == .Left && mhgui.selectable_usable(&d.selectable, d.owner) {
		d.clicked = true
		ev.used = true
	}
}

@(comp_on_pointer_ui={component=DropdownItem})
comp_on_pointer_ui_DropdownItem :: proc(item: ^DropdownItem, ev: ^mhgui.UI_Pointer_Event) {
	mhgui.selectable_pointer(&item.selectable, ev)
	if ev.kind == .Click && ev.button == .Left && mhgui.selectable_usable(&item.selectable, item.owner) {
		item.clicked = true
		ev.used = true
	}
}

// After mhgui's ui_tick (order -100), which sends the pointer events.
@(update={order=-99})
dropdown_tick :: proc(dt: f32) {
	w := engine.ctx_world()
	selected := mhgui.ui_selected()
	real_dt := time.delta_time(.Unscaled)
	keys := mhgui.ui_navigation() && engine.application_is_focused() && !mhgui.ui_keys_captured()
	submit := keys && mhgui.ui_submit_pressed()

	// The rows first: a row picked this frame, by the pointer or the submit
	// key, is known before its Dropdown looks.
	Pick :: struct {
		dropdown: engine.Transform_Handle,
		index:    i32,
	}
	picks := make([dynamic]Pick, context.temp_allocator)
	{
		it := engine.pool_iterator(dropdown_items(w))
		for item, _ in engine.pool_next(&it) {
			live := item.enabled && engine.transform_active_in_hierarchy(item.owner)
			chosen := live && selected == item.owner
			usable := live && mhgui.selectable_usable(&item.selectable, item.owner)
			if usable && chosen && submit do item.clicked = true
			if item.clicked && usable && item.dropdown != {} do append(&picks, Pick{item.dropdown, item.index})
			item.clicked = false
			mhgui.selectable_update(&item.selectable, item.owner, live, chosen, false, real_dt)
		}
	}

	it := engine.pool_iterator(dropdowns(w))
	for d, _ in engine.pool_next(&it) {
		d.changed = false
		live := d.enabled && engine.transform_active_in_hierarchy(d.owner)
		chosen := live && selected == d.owner
		usable := live && mhgui.selectable_usable(&d.selectable, d.owner)
		if d.list == {} {
			if usable && (d.clicked || (chosen && submit)) do dropdown_show(d)
		} else {
			close := !usable || (keys && input.key_pressed(.ESCAPE))
			for p in picks {
				if p.dropdown != d.owner do continue
				if p.index >= 0 do dropdown_set_value(d, int(p.index))
				close = true
			}
			// The selection left the list: by a direction key, or by code.
			now := mhgui.ui_selected()
			if now != d.blocker && now != d.owner && !_under(now, d.list) do close = true
			if close do dropdown_hide(d)
		}
		d.clicked = false
		mhgui.selectable_update(&d.selectable, d.owner, live, selected == d.owner, false, real_dt)
		// The caption follows the value, set by a pick or by code.
		if live {
			_, caption := engine.transform_get_comp(engine.Transform_Handle(d.caption.handle), Text)
			text_set(caption, dropdown_option(d))
		}
	}
}
