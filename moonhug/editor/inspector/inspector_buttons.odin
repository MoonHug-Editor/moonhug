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
import "../undo"

Inspector_Button :: struct {
	label:  cstring,
	row:    int,
	weight: f32,
	invoke: proc(comp: rawptr),
}

// typeid -> buttons sorted by (row, label) at generation time.
inspector_buttons: map[typeid][]Inspector_Button

// `above` selects which half of the (row-descending) list draws: the top
// block takes rows >= 0, the bottom block rows < 0.
draw_inspector_buttons :: proc(tid: typeid, comp_ptr: rawptr, above: bool) {
	btns, ok := inspector_buttons[tid]
	if !ok || len(btns) == 0 || comp_ptr == nil do return

	spacing := im.GetStyle().ItemSpacing.x
	i := 0
	for i < len(btns) {
		// One row: [i, j) share btns[i].row.
		j := i
		total_w: f32 = 0
		for j < len(btns) && btns[j].row == btns[i].row {
			total_w += max(btns[j].weight, 0.01)
			j += 1
		}
		if (btns[i].row >= 0) != above {
			i = j
			continue
		}
		avail := im.GetContentRegionAvail().x
		row_w := avail - spacing * f32(j - i - 1)
		for k in i ..< j {
			if k > i do im.SameLine()
			b := btns[k]
			width := row_w * max(b.weight, 0.01) / total_w
			id := fmt.ctprintf("%s##ibtn_%d", b.label, k)
			if im.Button(id, im.Vec2{width, 0}) {
				undo.comp_snapshot()
				b.invoke(comp_ptr)
				undo.comp_commit()
				mark_inspector_changed()
			}
		}
		i = j
	}
}
