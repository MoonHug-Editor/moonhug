package animation_editor

// The Animation component's STATES, drawn as the tree they are
// (docs/AnimationComponent.md): one section per layer, each holding the states
// gameplay plays — a clip, or a Blend1D with its children under it.
//
// This replaces the generic array rows `layers` would otherwise get. A tree of
// arrays-of-unions is exactly the shape the reflected field loop draws worst,
// and the thing an author wants to see — what can I play, and what does it
// blend — is not in those rows at all.
//
// The tree is AUTHORED data, not the playable graph. The graph holds only what
// is playing right now, so it can never be the thing you click to start a
// state. The Playable Graph window is the other half of the picture: this is
// what CAN run, that is what IS running.
//
// A play button therefore never touches graph nodes. While simulating it calls
// the driver (animation_play_entry) and lets the next tick rebuild the graph.
// In edit mode nothing ticks the component, so it drives the animation window's
// preview instead (view_animation.odin) — one preview in the editor, so a state
// and a clip scrub can never pose the same object at once.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import engine "moonhug:engine"
import anim "moonhug:packages/animation"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(anim.Animation), _animation_inspector)
}

@(private = "file")
_animation_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx) // clip, play_automatically, wrap_mode, speed
	a := cast(^anim.Animation)ctx.ptr
	if a == nil do return
	_states_section(a)
}

// Drag widgets in this tree share one whole-component undo session: it opens
// when a widget activates and closes when it deactivates, and only one widget is
// ever active. A drag WITHOUT a session is written straight onto the component
// with nothing recording it, so the inspector's baseline wins on the next frame
// and the value snaps back — which reads as "it drops to 0 all the time".
@(private = "file") _drag_sess: undo.Edit_Session
@(private = "file") _dragging: bool

@(private = "file")
_drag_session :: proc(changed: bool) {
	if im.IsItemActivated() && !_dragging {
		_drag_sess = inspector.structural_edit_begin("Edit State")
		_dragging = true
	}
	if changed do inspector.mark_inspector_changed()
	if im.IsItemDeactivated() && _dragging {
		inspector.structural_edit_end(&_drag_sess)
		_dragging = false
	}
}

// Which entry the name field is being typed into, so exactly one row owns an
// edit buffer at a time.
@(private = "file") _rename_id: i32
@(private = "file") _rename_buf: [64]byte

@(private = "file")
_states_section :: proc(a: ^anim.Animation) {
	im.SeparatorText("States")

	if len(a.layers) == 0 {
		im.TextDisabled("No layers. A layer holds the states gameplay plays.")
	}

	for li in 0 ..< len(a.layers) {
		im.PushIDInt(i32(li))
		_layer_rows(a, li)
		im.PopID()
	}

	if im.Button("Add Layer") {
		sess := inspector.structural_edit_begin("Add Layer")
		if a.layers == nil do a.layers = make([dynamic]anim.Animation_Layer)
		append(&a.layers, anim.Animation_Layer{entries = make([dynamic]anim.Animation_Entry)})
		inspector.structural_edit_end(&sess)
	}
	if len(a.layers) > 1 {
		im.SameLine()
		if im.Button("Remove Layer") {
			sess := inspector.structural_edit_begin("Remove Layer")
			l := &a.layers[len(a.layers) - 1]
			for &e in l.entries do delete(e.name)
			delete(l.entries)
			pop(&a.layers)
			inspector.structural_edit_end(&sess)
		}
	}
}

@(private = "file")
_layer_rows :: proc(a: ^anim.Animation, li: int) {
	label := strings.clone_to_cstring(fmt.tprintf("Layer %d", li), context.temp_allocator)
	// AllowOverlap: the node's frame spans the row, so without it the node
	// swallows every click meant for the buttons drawn on the same line.
	open := im.TreeNodeEx(label, {.DefaultOpen, .SpanAvailWidth, .FramePadding, .AllowOverlap})

	// Add buttons sit on the layer's own row, right-aligned, the way Add
	// Component does — the layer is what they add to.
	im.SameLine()
	w := im.CalcTextSize("+ Blend").x + im.CalcTextSize("+ State").x + im.GetStyle().FramePadding.x * 4 + im.GetStyle().ItemSpacing.x
	im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)
	if im.Button("+ State") do _entry_add(a, li, anim.Animation_Entry_Clip{}, "State", 0)
	im.SameLine()
	if im.Button("+ Blend") do _entry_add(a, li, anim.Animation_Entry_Blend1D{}, "Blend", 0)

	if !open do return
	defer im.TreePop()

	if len(a.layers[li].entries) == 0 {
		im.TextDisabled("Empty. Add a state or a blend.")
		return
	}
	// Top level only — a blend draws its own children, so walking every entry
	// here would draw them twice.
	i := 0
	for i < len(a.layers[li].entries) {
		e := &a.layers[li].entries[i]
		if e.parent != 0 {
			i += 1
			continue
		}
		if !_entry_row(a, li, e.id) do continue // removed: indices shifted
		i += 1
	}
}

// One state row. Returns false when the entry was REMOVED, so the caller knows
// the array shifted under it.
@(private = "file")
_entry_row :: proc(a: ^anim.Animation, li: int, id: i32) -> bool {
	e := anim.animation_entry(a, id)
	if e == nil do return true
	im.PushIDInt(id)
	defer im.PopID()

	_, is_blend := e.kind.(anim.Animation_Entry_Blend1D)

	// Both kinds are a foldout, so every state's name starts at the same x and
	// any of them can be collapsed. A clip holds one row, a blend holds its
	// value and its children.
	// AllowOverlap: the node's frame spans the row, so without it the node
	// swallows every click meant for the buttons drawn on the same line.
	open := im.TreeNodeEx("##entry", {.DefaultOpen, .SpanAvailWidth, .FramePadding, .AllowOverlap})
	im.SameLine()

	_name_field(e)
	im.SameLine()
	im.TextDisabled(is_blend ? "Blend1D" : "Clip")

	removed := _row_buttons(a, li, id)
	if removed {
		if open do im.TreePop()
		return false
	}

	if !open do return true
	defer im.TreePop()

	if !is_blend {
		_clip_field(a, e, "Clip")
		return true
	}

	// The blend's position on its axis. This is the same field
	// animation_blend_set writes, so dragging it here is what gameplay does.
	// Two-value form: the single-value pointer assertion PANICS on a mismatch
	// rather than returning nil.
	if b, is := &e.kind.(anim.Animation_Entry_Blend1D); is {
		lo, hi := _blend_extent(a, li, id)
		im.SetNextItemWidth(-1)
		_drag_session(im.SliderFloat("##value", &b.value, lo, hi, "value %.2f"))
	}

	children := 0
	i := 0
	for i < len(a.layers[li].entries) {
		child := &a.layers[li].entries[i]
		if child.parent != id {
			i += 1
			continue
		}
		children += 1
		if !_blend_child_row(a, li, child.id) do continue
		i += 1
	}
	if children == 0 do im.TextDisabled("No children. A blend with nothing to blend poses nothing.")
	if im.Button("+ Clip") do _entry_add(a, li, anim.Animation_Entry_Clip{}, "Clip", id)
	return true
}

// A child row: its clip and its position on the parent's axis.
@(private = "file")
_blend_child_row :: proc(a: ^anim.Animation, li: int, id: i32) -> bool {
	e := anim.animation_entry(a, id)
	if e == nil do return true
	im.PushIDInt(id)
	defer im.PopID()

	// Two lines, because the asset picker owns a full inspector row: sharing one
	// with it pushes the position off the panel, and the position is the whole
	// point of a 1D blend — without it every child looks alike.
	_clip_field(a, e, "")

	im.Indent(im.GetStyle().IndentSpacing)
	im.SetNextItemWidth(90)
	_drag_session(im.DragFloat("##pos", &e.pos.x, 0.01, 0, 0, "at %.2f"))
	if im.IsItemHovered({}) do im.SetTooltip("Where this clip sits on the blend axis")
	removed := _row_buttons(a, li, id, play = false)
	im.Unindent(im.GetStyle().IndentSpacing)
	return !removed
}

// Play and remove, right-aligned. Returns true when the entry was removed.
@(private = "file")
_row_buttons :: proc(a: ^anim.Animation, li: int, id: i32, play := true) -> bool {
	style := im.GetStyle()
	btn := im.GetFrameHeight()
	w := btn + style.ItemSpacing.x + (play ? btn + style.ItemSpacing.x : 0)
	im.SameLine()
	im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)

	if play {
		// Playing asks the DRIVER, never the graph: the graph holds only what
		// is already running, and this state is by definition not in it yet.
		//
		// In edit mode nothing ticks the component, so the same button drives
		// the animation window's preview instead — one preview for the whole
		// editor, so a state and a clip scrub can never pose the object at once.
		previewing := !engine.application_is_playing() && preview_entry(a.owner) == id
		icon: cstring = previewing ? icons.ICON_MD_STOP : icons.ICON_MD_PLAY_ARROW
		if im.Button(icon, im.Vec2{btn, btn}) {
			if engine.application_is_playing() {
				anim.animation_play_entry(a, id, 0)
			} else if previewing {
				preview_stop_entry()
			} else {
				preview_play_entry(a.owner, id)
			}
		}
		if im.IsItemHovered({}) {
			im.SetTooltip(previewing ? "Stop previewing this state" : "Play this state")
		}
		im.SameLine()
	}

	removed := false
	if im.Button(icons.ICON_MD_DELETE, im.Vec2{btn, btn}) {
		_entry_remove(a, li, id)
		removed = true
	}
	return removed
}

@(private = "file")
_name_field :: proc(e: ^anim.Animation_Entry) {
	im.SetNextItemWidth(140)
	if _rename_id == e.id {
		if im.InputText("##name", cstring(raw_data(_rename_buf[:])), len(_rename_buf), {.EnterReturnsTrue}) {
			_rename_commit(e)
		}
		if im.IsItemDeactivated() do _rename_commit(e)
		return
	}
	shown := e.name != "" ? e.name : "(unnamed)"
	if im.Button(strings.clone_to_cstring(shown, context.temp_allocator), im.Vec2{140, 0}) {
		_rename_id = e.id
		src := transmute([]u8)e.name
		n := min(len(src), len(_rename_buf) - 1)
		for i in 0 ..< len(_rename_buf) do _rename_buf[i] = 0
		copy(_rename_buf[:], src[:n])
	}
	if im.IsItemHovered({}) do im.SetTooltip("Click to rename. animation_find looks states up by this")
}

@(private = "file")
_rename_commit :: proc(e: ^anim.Animation_Entry) {
	text := string(cstring(raw_data(_rename_buf[:])))
	if text != e.name {
		sess := inspector.structural_edit_begin("Rename State")
		delete(e.name)
		e.name = strings.clone(text)
		inspector.structural_edit_end(&sess)
	}
	_rename_id = 0
}

@(private = "file")
_clip_field :: proc(a: ^anim.Animation, e: ^anim.Animation_Entry, label: cstring) {
	c, is_clip := &e.kind.(anim.Animation_Entry_Clip)
	if !is_clip do return
	prev := inspector.current_field_ext_filter
	inspector.current_field_ext_filter = "anim"
	defer inspector.current_field_ext_filter = prev

	before := c.clip
	inspector.draw_asset_guid_property(&c.clip, typeid_of(engine.Asset_GUID), label)
	if c.clip != before do inspector.mark_inspector_changed()
}

// The axis range a blend's slider spans: its children's positions, widened to
// at least one unit so a blend with one child (or none) still has a usable bar.
@(private = "file")
_blend_extent :: proc(a: ^anim.Animation, li: int, id: i32) -> (lo: f32, hi: f32) {
	found := false
	for &child in a.layers[li].entries {
		if child.parent != id do continue
		if !found {
			lo, hi, found = child.pos.x, child.pos.x, true
			continue
		}
		lo = min(lo, child.pos.x)
		hi = max(hi, child.pos.x)
	}
	if !found do return 0, 1
	if hi - lo < 0.0001 do return lo, lo + 1
	return lo, hi
}

@(private = "file")
_entry_add :: proc(a: ^anim.Animation, li: int, variant: anim.Animation_Entry_Kind, name: string, parent: i32) {
	sess := inspector.structural_edit_begin("Add State")
	defer inspector.structural_edit_end(&sess)

	if a.layers[li].entries == nil do a.layers[li].entries = make([dynamic]anim.Animation_Entry)
	id := anim.animation_entry_next_id(a)
	// A new child lands past the last sibling, so adding to a blend extends its
	// axis instead of landing on top of an existing child.
	x := f32(0)
	if parent != 0 {
		for &child in a.layers[li].entries {
			if child.parent == parent do x = max(x, child.pos.x + 1)
		}
	}
	append(&a.layers[li].entries, anim.Animation_Entry{
		id      = id,
		parent  = parent,
		pos     = {x, 0},
		name    = strings.clone(fmt.tprintf("%s %d", name, id)),
		kind = variant,
	})
}

// Removing a blend takes its children with it: a child whose parent is gone
// would never be reachable or playable, and would be invisible in this tree.
@(private = "file")
_entry_remove :: proc(a: ^anim.Animation, li: int, id: i32) {
	sess := inspector.structural_edit_begin("Remove State")
	defer inspector.structural_edit_end(&sess)

	entries := &a.layers[li].entries
	for i := len(entries) - 1; i >= 0; i -= 1 {
		e := &entries[i]
		if e.id != id && e.parent != id do continue
		delete(e.name)
		ordered_remove(entries, i)
	}
	if _rename_id == id do _rename_id = 0
}
