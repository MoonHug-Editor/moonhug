package inspector

// Component-level action buttons: procs carrying @(inspector_button={label=,
// row=, weight=}) render as button blocks framing the component's fields —
// HIGHER row renders HIGHER on screen: rows >= 0 stack at the TOP of the
// component (above the fields), rows < 0 below them. The proc's first
// parameter type selects the component; the generated registration calls the
// proc by name, so a rename is a compile error in
// inspector_buttons_generated.odin. Field-anchored buttons use
// `decor:button(...)` instead (decorators.odin).

import "core:fmt"
import im "moonhug:external/odin-imgui"

Inspector_Button :: struct {
	label:    cstring,
	row:      int,
	weight:   f32,
	show_in_array: bool, // also frame array ELEMENTS of this type (default true)
	invoke:   proc(comp: rawptr),
}

// typeid -> buttons sorted by (row, label) at generation time.
inspector_buttons: map[typeid][]Inspector_Button

// True while the inspector draws inside an ARRAY ELEMENT (set by
// draw_array_element). A type's buttons frame it wherever it draws — this
// flag is what show_in_array=false filters on, so a singular nested field
// still shows every button.
_in_array_element: bool

// What a click DOES, separated from the click itself so it can be driven
// without a UI (the button's wiring is otherwise only reachable by a real mouse
// press, which is where several multiedit bugs hid).
//
// The button runs on every selected object, not just the active one — a button
// is an action on a component, and Unity applies component actions across the
// selection. The whole sweep is one undo step.
inspector_button_invoke :: proc(b: Inspector_Button, comp_ptr: rawptr) {
	if b.invoke == nil || comp_ptr == nil do return

	sess := structural_edit_begin(string(b.label))
	b.invoke(comp_ptr)
	for peer in multi_peers() {
		if peer.base == nil || peer.base == comp_ptr do continue
		b.invoke(peer.base)
	}
	structural_edit_end(&sess)
}

// `above` selects which half of the (row-descending) list draws: the top
// block takes rows >= 0, the bottom block rows < 0. `element_ctx` marks a
// nested draw (array element) — buttons with show_in_array=false skip there.
draw_inspector_buttons :: proc(tid: typeid, comp_ptr: rawptr, above: bool, element_ctx: bool) {
	btns, ok := inspector_buttons[tid]
	if !ok || len(btns) == 0 || comp_ptr == nil do return

	spacing := im.GetStyle().ItemSpacing.x
	i := 0
	for i < len(btns) {
		// One row: [i, j) share btns[i].row (skipped buttons keep the row
		// intact for the others' widths).
		j := i
		total_w: f32 = 0
		n_drawn := 0
		for j < len(btns) && btns[j].row == btns[i].row {
			if !element_ctx || btns[j].show_in_array {
				total_w += max(btns[j].weight, 0.01)
				n_drawn += 1
			}
			j += 1
		}
		if (btns[i].row >= 0) != above || n_drawn == 0 {
			i = j
			continue
		}
		avail := im.GetContentRegionAvail().x
		row_w := avail - spacing * f32(n_drawn - 1)
		drawn := 0
		for k in i ..< j {
			b := btns[k]
			if element_ctx && !b.show_in_array do continue
			if drawn > 0 do im.SameLine()
			drawn += 1
			width := row_w * max(b.weight, 0.01) / total_w
			id := fmt.ctprintf("%s##ibtn_%d", b.label, k)
			if im.Button(id, im.Vec2{width, 0}) {
				inspector_button_invoke(b, comp_ptr)
			}
		}
		i = j
	}
}
