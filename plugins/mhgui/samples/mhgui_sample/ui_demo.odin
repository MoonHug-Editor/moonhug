package mhgui_sample

// The script of the UI demo scene: a card the pointer drags.

import "moonhug:packages/engine"
import mhgui "moonhug:packages/mhgui"

// Makes its node draggable, to show a component of your own taking pointer
// events (plugins/engine/ui_pointer.odin). It uses Down and keeps the drag,
// so it follows the pointer from the first pixel and no parent takes the
// drag. Its UiShape's border lights up while the pointer is over it.
@(component={menu="Demo/UIDemoDrag"})
@(typ_guid={guid = "b7e7e442-92de-4e24-9804-82d9f8b9462d"})
UIDemoDrag :: struct {
	using base:   engine.CompData `inspect:"-"`,
	border:       [4]f32 `decor:color()`, // the UiShape's border at rest
	border_hover: [4]f32 `decor:color()`, // and under the pointer
}

type_reset_UIDemoDrag :: proc(d: ^UIDemoDrag) {
	engine.comp_zero(d)
	d.border = {0.45, 0.5, 0.65, 1}
	d.border_hover = {1, 0.85, 0.3, 1}
}

@(comp_on_pointer_ui={component=UIDemoDrag})
comp_on_pointer_ui_UIDemoDrag :: proc(d: ^UIDemoDrag, ev: ^engine.UI_Pointer_Event) {
	#partial switch ev.kind {
	case .Enter, .Exit:
		if _, shape := engine.transform_get_comp(d.owner, mhgui.UiShape); shape != nil {
			shape.border_color = d.border_hover if ev.kind == .Enter else d.border
		}
	case .Down:
		if ev.button != .Left do return
		ev.used = true
		ev.own_drag = true
	case .Drag:
		// The movement in the canvas's own units, whatever its scale.
		if _, rt := engine.transform_get_comp(d.owner, engine.RectTransform); rt != nil {
			delta := engine.ui_pointer_canvas_delta(ev)
			rt.anchored_position.xy += delta
		}
	}
}
