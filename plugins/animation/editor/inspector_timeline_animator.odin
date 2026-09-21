package animation_editor

// The TimelineAnimator's OUTPUTS and STATES, drawn as the lists they are
// (docs/TimelineAnimator.md): the objects its timelines drive, then one section
// per layer holding the states gameplay plays — a whole timeline each.
//
// The same tree the Animation component gets (inspector_animation.odin), one
// level shallower: a Timeline_State is a flat entry in its layer, with no
// parent and no union of kinds, so Add is a plain button rather than a menu of
// variants. What carries over unchanged is the part that matters — every value
// row goes through inspector.field_edit_row, so the snapshot, the gesture
// bracket and the commit are the shared ones rather than this file's own.
//
// The timeline field draws as the reference picker every other reference field
// uses, filtered to PlayableDirector. It gets that for free because the field
// is an engine.Ref_Local — it was a bare engine.PPtr, which has no drawer, no
// handle resolution and no picker, so the reflected loop drew a local_id and a
// guid as raw numbers.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/icons"
import "moonhug:editor/inspector"
import "moonhug:editor/preview"
import "moonhug:editor/widgets"
import engine "moonhug:engine"
import anim "moonhug:packages/animation"
import seq "moonhug:packages/sequencer"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
timeline_animator_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(anim.TimelineAnimator), _timeline_animator_inspector)
	_ta_alt_open_pending = make(map[i32]bool, 16, runtime.default_allocator())
}

shutdown_timeline_animator_inspector :: proc() {
	delete(_ta_alt_open_pending)
	_ta_alt_open_pending = nil
}

@(private = "file")
_timeline_animator_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx) // speed
	a := cast(^anim.TimelineAnimator)ctx.ptr
	if a == nil do return
	_ta_states_section(a)
}

// Alt-click on a layer applies to every state under it, the same queue the
// Animation tree uses — imgui owns a node's open state, so the only way to set
// one is SetNextItemOpen before it draws. Keyed by state id, minted per
// component and never reused.
@(private = "file") _ta_alt_open_pending: map[i32]bool

// Which name field is being typed into, so exactly one row owns an edit buffer
// at a time. A state uses its own minted id, which is always positive; a layer
// has no id and takes a negative band keyed by index, so the two cannot
// collide.
@(private = "file") _ta_rename_id: i32
@(private = "file") _ta_rename_buf: [64]byte
@(private = "file") _RENAME_LAYER :: i32(-1) // -1, -2, ... by layer index

// --- Row drawers ----------------------------------------------------------------
// field_edit_row hands a drawer nothing but the field, and Odin procs are not
// closures, so a row's extra parameters travel here.

@(private = "file")
_ta_weight_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	if widgets.slider_float(inspector.field_row(label), cast(^f32)ptr, 0, 1) {
		inspector.mark_inspector_changed()
	}
}

@(private = "file")
_ta_speed_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	id := inspector.field_row(label)
	im.SetNextItemWidth(110)
	if im.DragFloat(id, cast(^f32)ptr, 0.01, 0, 0, "%.2f") do inspector.mark_inspector_changed()
	widgets.tooltip("Playback speed for this state. 0 runs at 1")
}

@(private = "file")
_ta_fade_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	id := inspector.field_row(label)
	im.SetNextItemWidth(110)
	if im.DragFloat(id, cast(^f32)ptr, 0.01, 0, 0, "%.2f s") do inspector.mark_inspector_changed()
	widgets.tooltip("Cross-fade duration INTO this state, unless the caller passes its own")
}

@(private = "file")
_ta_wrap_drawer :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	w := cast(^seq.Timeline_Wrap)ptr
	cur := i32(w^)
	id := inspector.field_row(label)
	im.SetNextItemWidth(110)
	if im.Combo(id, &cur, "Once\x00Loop\x00") && i32(w^) != cur {
		w^ = seq.Timeline_Wrap(cur)
		inspector.mark_inspector_changed()
	}
}

// The timeline row needs no drawer of its own: the field is an engine.Ref, so
// it gets the shared reference picker, and the scene loader resolves its handle
// like every other Ref. All this row supplies is the `ref:` filter the field
// declares, which a custom row has to set explicitly — nothing reads field tags
// on a row the reflected loop never walks.

// --- Sections -------------------------------------------------------------------

@(private = "file")
_ta_states_section :: proc(a: ^anim.TimelineAnimator) {
	im.SeparatorText("States")

	// The tree is single-object: a row names a state by id, and two selected
	// animators have their own states with their own ids.
	prev_peers := inspector.multi_set_peers(nil)
	defer inspector.multi_set_peers(prev_peers)

	if len(a.layers) == 0 {
		im.TextDisabled("No layers. A layer holds the states gameplay plays.")
	}

	for li in 0 ..< len(a.layers) {
		im.PushIDInt(i32(li))
		_ta_layer_rows(a, li)
		im.PopID()
	}

	if im.Button("Add Layer") {
		sess := inspector.structural_edit_begin("Add Layer")
		if a.layers == nil do a.layers = make([dynamic]anim.Animator_Layer)
		append(&a.layers, anim.Animator_Layer{
			name   = strings.clone(fmt.tprintf("Layer %d", len(a.layers))),
			weight = 1, // zero-neutral: a layer added here starts at full strength
			states = make([dynamic]anim.Timeline_State),
		})
		inspector.structural_edit_end(&sess)
	}
	if len(a.layers) > 1 {
		im.SameLine()
		if im.Button("Remove Layer") {
			sess := inspector.structural_edit_begin("Remove Layer")
			l := &a.layers[len(a.layers) - 1]
			for &st in l.states do delete(st.name)
			delete(l.name)
			delete(l.states)
			pop(&a.layers)
			inspector.structural_edit_end(&sess)
		}
	}
}

@(private = "file")
_ta_layer_rows :: proc(a: ^anim.TimelineAnimator, li: int) {
	l := &a.layers[li]

	// AllowOverlap: the node's frame spans the row, so without it the node
	// swallows every click meant for the buttons drawn on the same line.
	open := im.TreeNodeEx("##layer", {.DefaultOpen, .SpanAvailWidth, .FramePadding, .AllowOverlap})
	// The layer is the only row with foldouts beneath it.
	if im.IsItemToggledOpen() && im.GetIO().KeyAlt {
		for &st in l.states do _ta_alt_open_pending[st.id] = open
	}
	im.SameLine()

	// Layers carry a name here, unlike the Animation component's — it is what
	// animator_layer_weight and the doc's layer table refer to.
	_ta_name_field(_RENAME_LAYER - i32(li), &l.name, "Layer")
	im.SameLine()
	im.TextDisabled("Layer %d", i32(li))

	im.SameLine()
	w := im.CalcTextSize("Add State").x + im.GetStyle().FramePadding.x * 2
	im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)
	if im.Button("Add State") do _ta_state_add(a, li)

	if !open do return
	defer im.TreePop()

	_ta_row(a, &l.weight, typeid_of(f32), "Layer Weight", _ta_weight_drawer, "Weight")

	if len(l.states) == 0 {
		im.TextDisabled("Empty. Add a state to play a timeline here.")
		return
	}
	i := 0
	for i < len(l.states) {
		if !_ta_state_row(a, li, i) do continue // removed: indices shifted
		i += 1
	}
}

// One state row. Returns false when the state was REMOVED, so the caller knows
// the array shifted under it.
@(private = "file")
_ta_state_row :: proc(a: ^anim.TimelineAnimator, li, si: int) -> bool {
	st := &a.layers[li].states[si]
	im.PushIDInt(st.id)
	defer im.PopID()

	if v, queued := _ta_alt_open_pending[st.id]; queued {
		im.SetNextItemOpen(v)
		delete_key(&_ta_alt_open_pending, st.id)
	}
	open := im.TreeNodeEx("##state", {.DefaultOpen, .SpanAvailWidth, .FramePadding, .AllowOverlap})
	im.SameLine()

	_ta_name_field(st.id, &st.name, "State")
	im.SameLine()
	im.TextDisabled("Timeline")

	removed := _ta_row_buttons(a, li, si)
	if removed {
		if open do im.TreePop()
		return false
	}

	if !open do return true
	defer im.TreePop()

	// The state names the DIRECTOR, and `_ta_state_root` takes its owner as the
	// timeline root — the same step a bound target takes. Ref_Local, so the
	// picker offers scene objects only, which is the only place a timeline can
	// live.
	prev_ref := inspector.current_field_ref_target
	inspector.current_field_ref_target = "PlayableDirector"
	_ta_row(a, &st.timeline, typeid_of(engine.Ref_Local), "Timeline", inspector.draw_ref_local_property, "Timeline")
	inspector.current_field_ref_target = prev_ref

	_ta_row(a, &st.speed, typeid_of(f32), "State Speed", _ta_speed_drawer, "Speed")
	_ta_row(a, &st.wrap, typeid_of(seq.Timeline_Wrap), "Wrap", _ta_wrap_drawer, "Wrap")
	_ta_row(a, &st.fade, typeid_of(f32), "Fade", _ta_fade_drawer, "Fade")
	_ta_track_bindings(st)
	return true
}

// What the state's timeline drives: one row per track, showing that TRACK's
// own binding field — the animation track's Animation, the audio track's
// AudioSource — named by Track_Desc.binding_field, so the animator never names
// a kind. This is the reason the tree exists: every object a character depends
// on is read and edited in one place. The field lives on the track, and the
// row is a PROXY for it: inspector.property addresses it on the track
// component, so undo lands there and a prefab override records against the
// track's own instance. Editing here is editing the track.
@(private = "file")
_ta_track_bindings :: proc(st: ^anim.Timeline_State) {
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, st.timeline.handle) do return
	base := cast(^engine.CompData)engine.world_pool_get(w, st.timeline.handle)
	if base == nil do return
	_, d := engine.transform_get_comp(base.owner, seq.PlayableDirector)
	if d == nil do return
	tracks := seq.director_tracks(d)
	if len(tracks) == 0 do return

	im.AlignTextToFramePadding()
	im.TextDisabled("Tracks")
	for &tv in tracks {
		desc, ok := seq.track_desc(tv.kind)
		if !ok || desc.binding_field == "" do continue
		owned, raw := engine.transform_get_comp_key(tv.node, desc.track_key)
		if raw == nil do continue
		p, pok := inspector.inspect_comp(owned.handle)
		if !pok do continue
		// The name is a literal a track kind registers, so a miss is that
		// kind's bug — not something to skip quietly.
		b, err := inspector.property(p, desc.binding_field)
		if err != .None {
			fmt.panicf("track kind %v registers binding_field %q: %v", tv.kind, desc.binding_field, err)
		}
		im.PushIDInt(i32(tv.node.index))
		inspector.property_row(b, "Track Binding", draw_label = strings.clone_to_cstring(tv.name, context.temp_allocator))
		im.PopID()
	}
}

// --- Edit-mode state preview ------------------------------------------------
//
// Nothing ticks a TimelineAnimator outside simulation — timeline_animator_tick
// is an @(update) proc. So the States tree's play button drives a preview
// instead: pose the world right before the scene render, put it back right
// after (docs/PlayableGraph.md step 5, moonhug:editor/preview). The world
// holds authored values for the rest of the frame, so saves, undo and the
// inspector never see the pose.
//
// The advance itself is timeline_animator_step, the same proc the runtime tick
// calls, in .Preview_Play mode. A preview with its own advance would drift
// from play mode one fix at a time.

@(private = "file")
_ta_pv: struct {
	owner:   engine.Transform_Handle,
	state:   i32, // authored Timeline_State.id, 0 = not previewing
	applied: bool,
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
ta_preview_install :: proc() {
	preview.register({apply = _ta_preview_apply, restore = _ta_preview_restore})
}

// Play an authored state on `owner` in edit mode, from its start.
ta_preview_play :: proc(owner: engine.Transform_Handle, id: i32) {
	// Two posers previewing at once is confusing even though the preview stack
	// unwinds correctly, and both buttons mean "show me this animation".
	animation_preview_stop()
	_ta_pv.owner = owner
	_ta_pv.state = id
	_, a := engine.transform_get_comp(owner, anim.TimelineAnimator)
	if a == nil do return
	anim.animator_play(a, anim.State_Id(id))
}

// The state being previewed on `owner`, or 0.
ta_preview_state :: proc(owner: engine.Transform_Handle) -> i32 {
	if _ta_pv.owner != owner do return 0
	return _ta_pv.state
}

ta_preview_stop :: proc() {
	if _ta_pv.state == 0 do return
	if _, a := engine.transform_get_comp(_ta_pv.owner, anim.TimelineAnimator); a != nil {
		anim.animator_stop(a)
		anim.timeline_animator_release(a)
	}
	_ta_pv.state = 0
	_ta_pv.applied = false
}

@(private = "file")
_ta_preview_apply :: proc() {
	if _ta_pv.state == 0 do return
	// Simulation owns the component once it starts, and it ticks the animator
	// itself — a preview on top would advance it twice per frame.
	if engine.application_is_playing() {
		ta_preview_stop()
		return
	}
	w := engine.ctx_world()
	if !engine.pool_valid(w == nil ? nil : &w.transforms, engine.Handle(_ta_pv.owner)) {
		_ta_pv.state = 0
		return
	}
	_, a := engine.transform_get_comp(_ta_pv.owner, anim.TimelineAnimator)
	if a == nil {
		_ta_pv.state = 0
		return
	}

	// Build first: refreshing defaults needs bindings, and the graph is what
	// holds them.
	anim.timeline_animator_ensure_graph(a)
	anim.timeline_animator_refresh_defaults(a)
	anim.timeline_animator_step(a, im.GetIO().DeltaTime, .Preview_Play)
	_ta_pv.applied = true
}

@(private = "file")
_ta_preview_restore :: proc() {
	if !_ta_pv.applied do return
	_ta_pv.applied = false
	if _, a := engine.transform_get_comp(_ta_pv.owner, anim.TimelineAnimator); a != nil {
		anim.timeline_animator_write_defaults(a)
	}
}

// Play and remove, right-aligned. Returns true when the state was removed.
@(private = "file")
_ta_row_buttons :: proc(a: ^anim.TimelineAnimator, li, si: int) -> bool {
	style := im.GetStyle()
	btn := im.GetFrameHeight()
	im.SameLine()
	im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - (btn * 2 + style.ItemSpacing.x))

	// Simulating, the button plays the state on the live component. In edit
	// mode nothing ticks the animator, so the same button drives the preview
	// above — the Animation tree's states work the same way.
	id := a.layers[li].states[si].id
	playing := engine.application_is_playing()
	previewing := !playing && ta_preview_state(a.owner) == id
	if im.Button(previewing ? icons.ICON_MD_STOP : icons.ICON_MD_PLAY_ARROW, im.Vec2{btn, btn}) {
		switch {
		case playing:    anim.animator_play(a, anim.State_Id(id))
		case previewing: ta_preview_stop()
		case:            ta_preview_play(a.owner, id)
		}
	}
	widgets.tooltip(previewing ? "Stop previewing this state" : "Play this state")
	im.SameLine()

	removed := false
	if im.Button(icons.ICON_MD_DELETE, im.Vec2{btn, btn}) {
		_ta_state_remove(a, li, si)
		removed = true
	}
	return removed
}

// One value row. A state lives in a dynamic array, so the prefab override
// names the whole `layers` field — the granularity the undo step records too.
@(private = "file")
_ta_row :: proc(
	a: ^anim.TimelineAnimator,
	ptr: rawptr,
	tid: typeid,
	label: string,
	drawer: proc(ptr: rawptr, tid: typeid, label: cstring),
	draw_label: cstring,
) {
	inspector.custom_field_row(ptr, tid, label, drawer, draw_label,
		{&a.layers, typeid_of([dynamic]anim.Animator_Layer), "layers"})
}

// Click-to-rename, shared by layer and state rows. `key` identifies which row
// owns the buffer — states use their id, layers a negative one.
@(private = "file")
_ta_name_field :: proc(key: i32, name: ^string, kind: string) {
	im.SetNextItemWidth(140)
	if _ta_rename_id == key {
		if im.InputText("##name", cstring(raw_data(_ta_rename_buf[:])), len(_ta_rename_buf), {.EnterReturnsTrue}) {
			_ta_rename_commit(name)
		}
		if im.IsItemDeactivated() do _ta_rename_commit(name)
		return
	}
	shown := name^ != "" ? name^ : "(unnamed)"
	if im.Button(strings.clone_to_cstring(shown, context.temp_allocator), im.Vec2{140, 0}) {
		_ta_rename_id = key
		src := transmute([]u8)name^
		n := min(len(src), len(_ta_rename_buf) - 1)
		for i in 0 ..< len(_ta_rename_buf) do _ta_rename_buf[i] = 0
		copy(_ta_rename_buf[:], src[:n])
	}
	widgets.tooltip(kind == "State" ? "Click to rename. animator_find looks states up by this" : "Click to rename")
}

@(private = "file")
_ta_rename_commit :: proc(name: ^string) {
	text := string(cstring(raw_data(_ta_rename_buf[:])))
	if text != name^ {
		sess := inspector.structural_edit_begin("Rename")
		delete(name^)
		name^ = strings.clone(text)
		inspector.structural_edit_end(&sess)
	}
	_ta_rename_id = 0
}

@(private = "file")
_ta_state_add :: proc(a: ^anim.TimelineAnimator, li: int) {
	sess := inspector.structural_edit_begin("Add State")
	defer inspector.structural_edit_end(&sess)

	if a.layers[li].states == nil do a.layers[li].states = make([dynamic]anim.Timeline_State)
	id := anim.animator_state_next_id(a)
	append(&a.layers[li].states, anim.Timeline_State{
		id    = id,
		name  = strings.clone(fmt.tprintf("State %d", id)),
		speed = 1, // 0 also runs at 1, but an authored state should read as it plays
	})
}

@(private = "file")
_ta_state_remove :: proc(a: ^anim.TimelineAnimator, li, si: int) {
	sess := inspector.structural_edit_begin("Remove State")
	defer inspector.structural_edit_end(&sess)

	states := &a.layers[li].states
	if si < 0 || si >= len(states) do return
	if _ta_rename_id == states[si].id do _ta_rename_id = 0
	delete(states[si].name)
	ordered_remove(states, si)
}
