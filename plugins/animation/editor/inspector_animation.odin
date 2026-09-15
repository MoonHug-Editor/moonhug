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

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import engine "moonhug:engine"
import anim "moonhug:packages/animation"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(anim.Animation), _animation_inspector)
}

@(private = "file")
_animation_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx) // clip, play_automatically, speed
	a := cast(^anim.Animation)ctx.ptr
	if a == nil do return
	_states_section(a)
}

// NO value row here writes its own undo. Every one of them goes through
// inspector.field_edit_row, which is the single place the snapshot, the gesture
// bracket and the commit live (editor/inspector/field_edit.odin). It groups the
// widgets a row draws so any of them can own the gesture, opens the session from
// the inspector's owner stack, brackets a picker retroactively (a popup write
// has no gesture to observe), and closes on release.
//
// That is the whole rule, and it is why a custom inspector loses undo: undo is
// automatic per ROW DRAWN THROUGH field_edit_row, not per widget. A drawer that
// calls imgui directly has drawn a row that never went through it, so nothing
// snapshots it and nothing commits it. The value still changes — it was written
// straight onto the component — which is why the loss is invisible until Ctrl+Z.
//
// Rows whose value sits in a dynamic-array element record the WHOLE component.
// The session decides that itself: no offset from the component base names an
// entry, whose storage is a separate allocation (editor/undo/undo_session.odin).

// field_edit_row hands a drawer nothing but the field, and Odin procs are not
// closures, so a row's extra parameters travel here.
@(private = "file") _slider_lo, _slider_hi: f32

@(private = "file")
_slider_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if widgets.slider_float(inspector.field_row(label), cast(^f32)ptr, _slider_lo, _slider_hi) {
		inspector.mark_inspector_changed()
	}
}

@(private = "file")
_pos_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	im.SetNextItemWidth(90)
	if im.DragFloat(label, cast(^f32)ptr, 0.01, 0, 0, "at %.2f") do inspector.mark_inspector_changed()
	if im.IsItemHovered({}) do im.SetTooltip("Where this clip sits on the blend axis")
}

@(private = "file")
_wrap_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	w := cast(^anim.Animation_Wrap_Mode)ptr
	cur := i32(w^)
	id := inspector.field_row(label)
	im.SetNextItemWidth(110)
	if im.Combo(id, &cur, "Default\x00Once\x00Loop\x00") && i32(w^) != cur {
		w^ = anim.Animation_Wrap_Mode(cur)
		inspector.mark_inspector_changed()
	}
	if im.IsItemHovered({}) do im.SetTooltip("Default takes the clip's own wrap")
}

// One value row of the tree: the shared row transaction, then the prefab
// override its commit implies. An entry has no path from the component base,
// so the override names the whole `layers` field — the same granularity the
// undo step records. No-op on an object that is not a prefab instance.
@(private = "file")
_tree_row :: proc(
	a: ^anim.Animation,
	ptr: rawptr,
	tid: typeid,
	label: string,
	drawer: proc(ptr: rawptr, tid: typeid, label: cstring),
	draw_label: cstring,
) {
	finished := inspector.field_edit_row(ptr, tid, 0, label, drawer, draw_label)
	inspector.record_nested_override(&a.layers, typeid_of([dynamic]anim.Animation_Layer), "layers", finished)
}

// Which entry the name field is being typed into, so exactly one row owns an
// edit buffer at a time.
@(private = "file") _rename_id: i32
@(private = "file") _rename_buf: [64]byte

@(private = "file")
_states_section :: proc(a: ^anim.Animation) {
	im.SeparatorText("States")

	// The tree is single-object. A row names an entry by id, and two selected
	// objects have their own trees with their own ids, so one object's row means
	// nothing on another. Clearing the peers is what stops field_edit_row from
	// trying: it writes a row onto every peer at the row's offset, and an entry
	// has no offset from the component base.
	prev_peers := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev_peers)

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

	// One Add button on the layer's own row, right-aligned, the way Add
	// Component does — the layer is what it adds to, and the menu is the list
	// of kinds a state can be.
	im.SameLine()
	w := im.CalcTextSize("Add").x + im.GetStyle().FramePadding.x * 2
	im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)
	if im.Button("Add") do im.OpenPopup("##add_state")
	if im.BeginPopup("##add_state") {
		info := _entry_kind_info()
		for v, idx in info.variants {
			label := strings.clone_to_cstring(_kind_name(v), context.temp_allocator)
			if im.MenuItem(label, nil, false, true) do _entry_add(a, li, idx, 0)
		}
		im.EndPopup()
	}

	if !open do return
	defer im.TreePop()

	if len(a.layers[li].entries) == 0 {
		im.TextDisabled("Empty. Add picks the kind of state.")
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

	_wrap_field(a, e)
	if !is_blend {
		_clip_field(a, e, "Clip")
		return true
	}

	// The blend's position on its axis. This is the same field
	// animation_blend_set writes, so dragging it here is what gameplay does.
	// Two-value form: the single-value pointer assertion PANICS on a mismatch
	// rather than returning nil.
	if b, is := &e.kind.(anim.Animation_Entry_Blend1D); is {
		_slider_lo, _slider_hi = _blend_extent(a, li, id)
		_tree_row(a, &b.value, typeid_of(f32), "Blend Value", _slider_drawer, "Value")
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
	// A 1D blend samples its children as clips, so its children are clips —
	// no menu to pick from here.
	if im.Button("+ Clip") do _entry_add(a, li, _kind_index(typeid_of(anim.Animation_Entry_Clip)), id)
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
	_tree_row(a, &e.pos.x, typeid_of(f32), "Blend Position", _pos_drawer, "##pos")
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

// Whether this state loops, as a per-STATE override of its clip. Default is the
// usual answer — the motion knows whether it is cyclic — so the combo shows the
// clip's own wrap when nothing overrides it.
@(private = "file")
_wrap_field :: proc(a: ^anim.Animation, e: ^anim.Animation_Entry) {
	// In the body rather than on the header row: the header already carries the
	// name, the kind and the right-aligned buttons, and a fourth widget there
	// runs into them on the longer "Blend1D" rows.
	_tree_row(a, &e.wrap, typeid_of(anim.Animation_Wrap_Mode), "Wrap", _wrap_drawer, "Wrap")
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

	// A picker: the value lands from inside a popup with no gesture to observe,
	// so the row is the thing that brackets it, after the fact, with the value
	// it snapshotted before the draw.
	_tree_row(a, &c.clip, typeid_of(engine.Asset_GUID), "Clip", inspector.draw_asset_guid_property, label)
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

// The kinds a state can be, read from the union itself — a new variant appears
// in the Add menu without an edit here.
@(private = "file")
_entry_kind_info :: proc() -> runtime.Type_Info_Union {
	ti := runtime.type_info_base(type_info_of(anim.Animation_Entry_Kind))
	info, _ := ti.variant.(runtime.Type_Info_Union)
	return info
}

// "animation.Animation_Entry_Blend1D" -> "Blend1D". The menu names the kind,
// not the type.
@(private = "file")
_kind_name :: proc(ti: ^runtime.Type_Info) -> string {
	name := fmt.tprintf("%v", ti)
	if i := strings.last_index_byte(name, '.'); i >= 0 do name = name[i + 1:]
	return strings.trim_prefix(name, "Animation_Entry_")
}

@(private = "file")
_kind_index :: proc(tid: typeid) -> int {
	info := _entry_kind_info()
	for v, i in info.variants {
		if v.id == tid do return i
	}
	fmt.panicf("%v is not a variant of Animation_Entry_Kind", tid)
}

@(private = "file")
_entry_add :: proc(a: ^anim.Animation, li: int, variant_index: int, parent: i32) {
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
	info := _entry_kind_info()
	append(&a.layers[li].entries, anim.Animation_Entry{
		id     = id,
		parent = parent,
		pos    = {x, 0},
		name   = strings.clone(fmt.tprintf("%s %d", _kind_name(info.variants[variant_index]), id)),
	})
	// The tag is set through the inspector's own union helper, so the tag
	// encoding lives in one place rather than being re-derived per package.
	e := &a.layers[li].entries[len(a.layers[li].entries) - 1]
	tag_ptr := rawptr(uintptr(rawptr(&e.kind)) + info.tag_offset)
	inspector.union_set_variant(&e.kind, tag_ptr, info, variant_index, record_undo = false)
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
