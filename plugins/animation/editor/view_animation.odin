package animation_editor

// Animation window — clip authoring on the PlayableGraph scrub path
// (docs/PlayableGraph.md steps 5+6): scrub preview plus dopesheet and curve
// editing for the clips on the selected object's Animation component.
//
// PREVIEW (step 5): never leaks into saved data. Each frame:
//   1. the window UI sets the scrub state (clip, time, on/off),
//   2. animation_preview_apply refreshes the binding defaults from the live
//      transforms, evaluates the clip at the scrub time and applies the pose,
//   3. the scene and game views render the posed world,
//   4. animation_preview_restore writes the defaults back.
// Outside that render window the world holds authored values, so saves, undo
// and the inspector are untouched by construction — there is no preview state
// to revert when preview ends, the target dies or its scene unloads.
//
// EDITING (step 6): keyframe operations edit the clip's ASSET DOCUMENT (the
// session registry the project inspector uses), so every operation is a
// whole-document undo step re-found by guid. Edits sync into the engine's
// clip cache (animation_clip_preview) the way material edits live-preview —
// that cache is what the scrub preview and any playing Animation component
// sample. Save writes the document to the .anim file; unsaved edits revert
// next editor run, same as materials.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "moonhug:engine"
import gfx "moonhug:engine/gfx"
import anim "moonhug:packages/animation"
import ser "moonhug:engine/serialization"
import "moonhug:editor/inspector"
import "moonhug:editor/menu"
import "moonhug:editor/undo"
import "moonhug:editor/preview"
import "moonhug:editor/widgets"
import "moonhug:editor/icons"

// Property column width, dragged via the pane splitter between it and the
// time canvas.
@(private = "file") _anim_left_w: f32 = 200
@(private = "file") _ANIM_MIN_LEFT_W :: f32(120)
@(private = "file") _ANIM_MIN_CANVAS_W :: f32(80)
@(private = "file") _ANIM_RULER_H :: f32(22)
@(private = "file") _ANIM_ROW_H :: f32(20)
@(private = "file") _ANIM_PAD_X :: f32(10) // time gutter inside the canvas
@(private = "file") _ANIM_KEY_R :: f32(4)  // key diamond half-size
@(private = "file") _ANIM_HIT :: f32(6)    // key hit-test radius

// Curve colors per value component (x red, y green, z blue, w grey).
@(private = "file")
_ANIM_COMP_COLS :: [4]im.Vec4{
	{0.91, 0.35, 0.35, 1},
	{0.42, 0.85, 0.42, 1},
	{0.40, 0.58, 1.00, 1},
	{0.75, 0.75, 0.75, 1},
}

// One key in the sheet: which channel row, which key in it.
@(private = "file")
_Key_Ref :: struct {
	ch:  int,
	key: int,
}

@(private = "file")
_Anim_Mode :: enum {
	Dopesheet,
	Curves,
}

@(private = "file")
_pv: struct {
	active:  bool, // preview on: the world renders the scrubbed pose
	applied: bool, // pose applied this frame, restore pending
	owner:   engine.Transform_Handle, // the Animation component's transform
	clip:    engine.Asset_GUID,
	time:    f32,
	graph:     anim.Playable_Graph, // the component's FULL authored graph
	binding:   anim.Animation_Binding,
	node:      anim.Playable_Handle, // the scrubbed clip's node (weight 1)
	graph_sig: u64, // authored clip set the graph was built from
	ready:     bool,

	playing:   bool, // transport running: time advances every frame
	recording: bool, // armed: an edited animated field keys itself at the playhead
	// Live value of each channel when recording armed (or last keyed), parallel
	// to clip.channels. A channel whose live value leaves this is a user edit,
	// which is what recording keys — no inspector hook needed, and scrubbing
	// alone never keys because authored values do not move with the playhead.
	rec_shadow: [dynamic][4]f32,

	mode:      _Anim_Mode,
	sel_ch:    int, // selected channel row, -1 = none
	sel_key:   int, // PRIMARY selected key in sel_ch, -1 = none
	// Every selected key, primary included. A drag moves all of them and
	// Delete removes all of them; the primary is what the value footer edits,
	// so a single-key selection behaves exactly as before.
	sel:       [dynamic]_Key_Ref,
	drag_key:  bool, // canvas key drag in progress (undo snapshot open)
	drag_comp: int,  // curves: value component the drag edits, -1 = time only
	drag_from: f32,  // time under the cursor when the drag began
	drag_t0:   [dynamic]f32, // each selected key's time then, parallel to sel
	// Box select in progress, and where it started (screen space).
	box:       bool,
	box_from:  im.Vec2,

	// Time-axis view, the sequencer's model: zoom is a multiple of the scale
	// that fits the whole clip, so 1 is "fit" and pan is then pinned to 0.
	// pan is the time at the canvas's left edge.
	zoom:      f32,
	pan:       f32,
	wheel:     widgets.Wheel_Lock, // one wheel axis per gesture
	sync:      bool, // document edited this frame -> push to the clip cache
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_preview_install :: proc() {
	preview.register({apply = animation_preview_apply, restore = animation_preview_restore})
	preview.register_view({draw = _animation_views_draw})
}

// Both animation views in one entry: visibility is the menu's persisted
// flags, and the window that is CLOSED must still stop its preview.
@(private = "file")
_animation_views_draw :: proc() {
	if menu.show_animation {
		draw_animation_view()
	} else {
		animation_preview_stop()
	}
	if menu.show_playable_graph {
		draw_playable_graph_view()
	}
}

@(phase={key=engine.Phase.EditorShutdown, order=1, mode=Editor})
animation_views_shutdown :: proc() {
	shutdown_playable_graph_view()
	shutdown_animation_view()
}

shutdown_animation_view :: proc() {
	_pv_teardown()
}

// Closing the window ends the preview. Called from the main
// loop when the window toggle is off.
animation_preview_stop :: proc() {
	_pv.active = false
}

@(private = "file")
_pv_teardown :: proc() {
	if _pv.ready {
		anim.playable_graph_destroy(&_pv.graph)
		anim.animation_binding_destroy(&_pv.binding)
	}
	_pv.ready = false
	_pv.node = {}
}

@(private = "file")
_pv_deselect :: proc() {
	_pv.sel_ch = -1
	_pv.sel_key = -1
	clear(&_pv.sel)
	_pv.drag_key = false
	_pv.box = false
}

// --- Key selection ---------------------------------------------------------------------

// Replace the selection with one key, which becomes primary.
@(private = "file")
_pv_sel_set :: proc(ch, key: int) {
	clear(&_pv.sel)
	append(&_pv.sel, _Key_Ref{ch, key})
	_pv.sel_ch = ch
	_pv.sel_key = key
}

// Add a key to the selection, or drop it when already there (additive click).
// The clicked key becomes primary either way it stays selected.
@(private = "file")
_pv_sel_toggle :: proc(ch, key: int) {
	for r, i in _pv.sel {
		if r.ch == ch && r.key == key {
			ordered_remove(&_pv.sel, i)
			// The primary went with it: fall back to any remaining key.
			if _pv.sel_ch == ch && _pv.sel_key == key {
				if len(_pv.sel) > 0 {
					_pv.sel_ch = _pv.sel[0].ch
					_pv.sel_key = _pv.sel[0].key
				} else {
					_pv.sel_key = -1
				}
			}
			return
		}
	}
	append(&_pv.sel, _Key_Ref{ch, key})
	_pv.sel_ch = ch
	_pv.sel_key = key
}

@(private = "file")
_pv_sel_has :: proc(ch, key: int) -> bool {
	for r in _pv.sel {
		if r.ch == ch && r.key == key do return true
	}
	return false
}

// Drop selection entries a document edit has invalidated (a channel or key
// removed by undo, or by deleting keys).
@(private = "file")
_pv_sel_prune :: proc(clip: ^anim.AnimationClip) {
	for i := len(_pv.sel) - 1; i >= 0; i -= 1 {
		r := _pv.sel[i]
		if r.ch < 0 || r.ch >= len(clip.channels) || r.key < 0 || r.key >= len(clip.channels[r.ch].times) {
			ordered_remove(&_pv.sel, i)
		}
	}
}

// The additive-selection modifier: the platform command key, as elsewhere in
// the editor.
@(private = "file")
_pv_additive :: proc() -> bool {
	io := im.GetIO()
	return io.KeyCtrl || io.KeySuper
}

// --- Frame snapping --------------------------------------------------------------------
//
// Keys and the playhead land on frame boundaries, so a clip authored here
// plays the same at any sample rate. Imported keys are left where they are:
// only what the user moves or creates snaps. Alt places freely, for matching
// an imported time exactly.

@(private = "file")
_pv_snap_time :: proc(clip: ^anim.AnimationClip, t: f32) -> f32 {
	if im.GetIO().KeyAlt do return t
	return anim.animation_snap_to_frame(clip, t)
}

// The scrub preview's live graph, for the Playable Graph visualizer — nil
// unless the preview is on for `owner` and its graph exists.
@(private)
_pv_preview_graph :: proc(owner: engine.Transform_Handle) -> ^anim.Playable_Graph {
	if !_pv.active || !_pv.ready || _pv.owner != owner do return nil
	return &_pv.graph
}

// The Animation component the window targets: on the active selection or its
// nearest ancestor, so
// selecting a child bone keeps the window on the animated root. Shared with
// the Playable Graph visualizer, which targets identically.
@(private)
_pv_target :: proc() -> (owner: engine.Transform_Handle, a: ^anim.Animation) {
	w := engine.ctx_world()
	tH := engine.inspector_active_selection()
	for engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		if _, comp := engine.transform_get_comp(tH, anim.Animation); comp != nil {
			return tH, comp
		}
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do break
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return {}, nil
}

// Every clip reachable from the component: the default clip plus the authored
// layers' clips, deduplicated, temp-allocated.
@(private = "file")
_pv_clips :: proc(a: ^anim.Animation) -> []engine.Asset_GUID {
	clips := make([dynamic]engine.Asset_GUID, context.temp_allocator)
	_pv_clips_add(&clips, a.clip)
	for &l in a.layers {
		for c in l.clips do _pv_clips_add(&clips, c)
	}
	return clips[:]
}

@(private = "file")
_pv_clips_add :: proc(clips: ^[dynamic]engine.Asset_GUID, g: engine.Asset_GUID) {
	if g == {} do return
	for c in clips^ {
		if c == g do return
	}
	append(clips, g)
}

// Shared with the Playable Graph visualizer's clip node labels.
@(private)
_pv_clip_name :: proc(g: engine.Asset_GUID) -> string {
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g)); ok {
		return filepath.stem(path)
	}
	return "(missing clip)"
}

// --- Document access and undo --------------------------------------------------------

// The selected clip's asset document — the edit target. Refetched every frame:
// undo/redo swaps the document payload, so pointers never survive a frame.
@(private = "file")
_pv_doc :: proc() -> (doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if _pv.clip == {} do return nil, nil
	path, ok := engine.asset_db_get_path(uuid.Identifier(_pv.clip))
	if !ok do return nil, nil
	d := inspector.asset_doc_get(path)
	if d == nil || d.data.id != typeid_of(anim.AnimationClip) do return nil, nil
	return d, cast(^anim.AnimationClip)d.data.data
}

// The animation view edits a document across frames (dragging a keyframe), so
// its edit is a session like any other — opened when the gesture starts, closed
// when it ends. See docs/Undo.md.
@(private = "file")
_pv_session: undo.Edit_Session

// One whole-document undo step: the session captures the document before the
// mutation and records the result after. Drags open on press and close on
// release, mutating in between.
@(private = "file")
_pv_edit_begin :: proc(doc: ^inspector.Asset_Doc) {
	// Idempotent: the drag calls this on activation, and a second call while the
	// same gesture is open would otherwise capture the already-edited value.
	if undo.edit_session_active(&_pv_session) do return
	_pv_session = undo.edit_session_begin(
		{undo.edit_target_asset(doc.guid, doc.data.id)}, "Animation Edit")
}

@(private = "file")
_pv_edit_commit :: proc(doc: ^inspector.Asset_Doc) {
	undo.edit_session_end(&_pv_session)
	_pv_mark_edited(doc)
}

@(private = "file")
_pv_mark_edited :: proc(doc: ^inspector.Asset_Doc) {
	doc.dirty = true
	_pv.sync = true
}

// The inspector's field convention: the session opens when the widget
// activates and commits when it deactivates after an edit — one undo step per
// drag/typing session. Rotation keys renormalize at commit so slerp sampling
// stays valid without fighting the drag.
@(private = "file")
_pv_field_undo :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, changed: bool) {
	if im.IsItemActivated() do _pv_edit_begin(doc)
	if changed do _pv_mark_edited(doc)
	if im.IsItemDeactivatedAfterEdit() {
		if _pv_sel_valid(clip) {
			ch := &clip.channels[_pv.sel_ch]
			if ch.path == .Rotation do _pv_normalize_rot_key(ch, _pv.sel_key)
		}
		_pv_edit_commit(doc)
	}
}

@(private = "file")
_pv_normalize_rot_key :: proc(ch: ^anim.Animation_Channel, k: int) {
	v := ch.values[k]
	if l := linalg.length(v); l > 0.0001 do ch.values[k] = (1.0 / l) * v
}

@(private = "file")
_pv_sel_valid :: proc(clip: ^anim.AnimationClip) -> bool {
	if _pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels) do return false
	return _pv.sel_key >= 0 && _pv.sel_key < len(clip.channels[_pv.sel_ch].times)
}

// Value lanes a channel edits: transform channels by path, property channels
// by the LIVE field kind (clip_property.odin — the file stores untyped
// floats). An unresolved property channel edits one lane, painted yellow in
// the row list.
@(private = "file")
_pv_ch_ncomp :: proc(ch: ^anim.Animation_Channel) -> int {
	if anim.animation_channel_is_property(ch) {
		if loc, ok := anim._prop_meta(ch.component, ch.field); ok {
			#partial switch loc.kind {
			case .Vec2: return 2
			case .Vec3: return 3
			case .Vec4: return 4
			}
			return 1
		}
		return 1
	}
	return ch.path == .Rotation ? 4 : 3
}

// Row label + resolved flag: transform channels are always resolved,
// property channels resolve their component guid and field path.
@(private = "file")
_pv_ch_label :: proc(ch: ^anim.Animation_Channel) -> (label: cstring, resolved: bool) {
	target := ch.target == "" ? "(self)" : ch.target
	if !anim.animation_channel_is_property(ch) {
		return fmt.ctprintf("%s : %v", target, ch.path), true
	}
	comp_name := "?"
	if guid, gerr := uuid.read(ch.component); gerr == nil {
		if tid, ok := engine.get_typeid_by_guid_ok(guid); ok {
			comp_name = fmt.tprintf("%v", tid)
			if dot := strings.last_index_byte(comp_name, '.'); dot >= 0 {
				comp_name = comp_name[dot + 1:]
			}
		}
	}
	_, mok := anim._prop_meta(ch.component, ch.field)
	return fmt.ctprintf("%s : %s.%s", target, comp_name, ch.field), mok
}

// --- Keyframe operations --------------------------------------------------------------

// Insert a key at `t` sampling the curve's current value there, so adding a
// key never changes the curve's shape.
@(private = "file")
_pv_add_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx: int, t: f32) {
	if ch_idx < 0 || ch_idx >= len(clip.channels) do return
	ch := &clip.channels[ch_idx]
	t := clamp(t, 0, clip.length)
	for kt in ch.times {
		if abs(kt - t) < 0.0005 do return
	}
	v := anim._animation_channel_sample(ch, t)
	idx := len(ch.times)
	for kt, i in ch.times {
		if kt > t {
			idx = i
			break
		}
	}
	_pv_edit_begin(doc)
	inject_at(&ch.times, idx, t)
	inject_at(&ch.values, idx, v)
	_pv_sel_set(ch_idx, idx)
	_pv_edit_commit(doc)
}

// The last key of a channel stays — an empty channel samples to zero, which
// is never what a delete meant.
@(private = "file")
// Deletes every selected key in one undo step. A channel left with no keys
// goes with them: a keyless channel animates nothing, so the property row
// disappears rather than lingering empty.
_pv_delete_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if !_pv_sel_valid(clip) do return
	_pv_sel_prune(clip)
	if len(_pv.sel) == 0 do return

	// Highest key index first, so each removal cannot shift the next one.
	refs := make([dynamic]_Key_Ref, 0, len(_pv.sel), context.temp_allocator)
	append(&refs, .._pv.sel[:])
	slice.sort_by(refs[:], proc(a, b: _Key_Ref) -> bool {
		return a.ch != b.ch ? a.ch > b.ch : a.key > b.key
	})

	_pv_edit_begin(doc)
	for r in refs {
		ch := &clip.channels[r.ch]
		ordered_remove(&ch.times, r.key)
		ordered_remove(&ch.values, r.key)
	}
	// Emptied channels, highest index first for the same reason.
	for i := len(clip.channels) - 1; i >= 0; i -= 1 {
		if len(clip.channels[i].times) > 0 do continue
		_pv_channel_remove(clip, i)
	}
	_pv_deselect() // channel indices may have shifted
	_pv_edit_commit(doc)
}

// Frees a channel's own allocations and drops it from the clip.
@(private = "file")
_pv_channel_remove :: proc(clip: ^anim.AnimationClip, i: int) {
	ch := &clip.channels[i]
	delete(ch.target)
	delete(ch.component)
	delete(ch.field)
	delete(ch.times)
	delete(ch.values)
	ordered_remove(&clip.channels, i)
}

// --- Add Property ------------------------------------------------------------------------
//
// The owner's subtree as nested menus: per object the three transform
// channels, then each component with its animatable POD leaves enumerated by
// reflection (the same kinds the runtime applies — clip_property.odin).

@(private = "file") _PV_PROP_MAX_DEPTH :: 6 // object recursion cap

@(private = "file")
_pv_add_prop_object :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, tH: engine.Transform_Handle, path: string, depth: int) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return

	label := path == "" ? "(self)" : path
	if im.BeginMenu(fmt.ctprintf("%s##obj", label)) {
		for p in anim.Animation_Path {
			if im.MenuItem(fmt.ctprintf("Transform.%v", p)) {
				_pv_add_channel_transform(doc, clip, path, p, tH)
			}
		}
		for c in t.components {
			tid := engine.get_typeid_by_type_key(c.handle.type_key)
			if tid == nil do continue
			comp_name := fmt.tprintf("%v", tid)
			if dot := strings.last_index_byte(comp_name, '.'); dot >= 0 {
				comp_name = comp_name[dot + 1:]
			}
			leaves := make([dynamic]string, context.temp_allocator)
			_pv_prop_leaves(tid, "", &leaves, 0)
			if len(leaves) == 0 do continue
			im.Separator()
			if im.BeginMenu(fmt.ctprintf("%s##c%d", comp_name, c.handle.index)) {
				guid_str := uuid.to_string(engine.get_guid_by_type_key(c.handle.type_key), context.temp_allocator)
				for field in leaves {
					if im.MenuItem(fmt.ctprintf("%s", field)) {
						_pv_add_channel_property(doc, clip, path, guid_str, field, tH)
					}
				}
				im.EndMenu()
			}
		}
		im.EndMenu()
	}

	if depth >= _PV_PROP_MAX_DEPTH do return
	for child in t.children {
		ct := engine.pool_get(&w.transforms, child.handle)
		if ct == nil do continue
		child_path := path == "" ? ct.name : fmt.tprintf("%s/%s", path, ct.name)
		_pv_add_prop_object(doc, clip, engine.Transform_Handle(child.handle), child_path, depth + 1)
	}
}

// Animatable leaves of a component type as dotted field paths. Walks plain
// struct nesting the way the runtime resolver does, skipping identity
// plumbing (base) and reference types (never animatable).
@(private = "file")
_pv_prop_leaves :: proc(tid: typeid, prefix: string, out: ^[dynamic]string, depth: int) {
	if depth > 4 do return
	names := reflect.struct_field_names(tid)
	types := reflect.struct_field_types(tid)
	for i in 0 ..< len(names) {
		name := names[i]
		if name == "base" do continue
		ftid := types[i].id
		if ftid == typeid_of(engine.PPtr) || ftid == typeid_of(engine.Ref) ||
		   ftid == typeid_of(engine.Ref_Local) || ftid == typeid_of(engine.Owned) {
			continue
		}
		full := prefix == "" ? name : fmt.tprintf("%s.%s", prefix, name)
		if _, ok := anim._prop_kind_of(ftid); ok {
			append(out, strings.clone(full, context.temp_allocator))
			continue
		}
		ti := runtime.type_info_base(type_info_of(ftid))
		if _, is_struct := ti.variant.(runtime.Type_Info_Struct); is_struct {
			_pv_prop_leaves(ftid, full, out, depth + 1)
		}
	}
}

@(private = "file")
_pv_add_channel_transform :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, target: string, path: anim.Animation_Path, tH: engine.Transform_Handle) {
	for &c in clip.channels {
		if !anim.animation_channel_is_property(&c) && c.target == target && c.path == path do return
	}
	w := engine.ctx_world()
	v: [4]f32
	if t := engine.pool_get(&w.transforms, engine.Handle(tH)); t != nil {
		switch path {
		case .Position: v.xyz = t.position
		case .Rotation: v = t.rotation
		case .Scale:    v.xyz = t.scale
		}
	}
	_pv_append_channel(doc, clip, anim.Animation_Channel{
		target = strings.clone(target),
		path   = path,
	}, v)
}

@(private = "file")
_pv_add_channel_property :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, target: string, guid_str: string, field: string, tH: engine.Transform_Handle) {
	for &c in clip.channels {
		if c.target == target && c.component == guid_str && c.field == field do return
	}
	// First key holds the field's CURRENT value, so adding a property never
	// visibly changes the object.
	v: [4]f32
	step := false
	if ptr, kind, leaf, ok := anim._prop_locate(tH, guid_str, field); ok {
		v = anim._prop_read(ptr, kind, leaf)
		step = anim.prop_kind_discrete(kind)
	}
	_pv_append_channel(doc, clip, anim.Animation_Channel{
		target    = strings.clone(target),
		component = strings.clone(guid_str),
		field     = strings.clone(field),
		step      = step,
	}, v)
}

@(private = "file")
_pv_append_channel :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch: anim.Animation_Channel, v: [4]f32) {
	ch := ch
	_pv_edit_begin(doc)
	ch.times = make([dynamic]f32)
	ch.values = make([dynamic][4]f32)
	append(&ch.times, 0)
	append(&ch.values, v)
	append(&clip.channels, ch)
	_pv_sel_set(len(clip.channels) - 1, 0)
	_pv_edit_commit(doc)
}

// A dragged key stays between its neighbors (and inside the clip), so the
// times array keeps its sort order without reindexing mid-drag.
@(private = "file")
_pv_drag_time_bounds :: proc(ch: ^anim.Animation_Channel, k: int, length: f32) -> (lo, hi: f32) {
	lo = k > 0 ? ch.times[k - 1] : 0
	hi = k < len(ch.times) - 1 ? ch.times[k + 1] : length
	return
}

// Which keys of channel `ch_idx` are selected, as a mask parallel to its
// times — the shape animation_key_bounds takes. Temp-allocated per query,
// which only happens while a drag is live.
@(private = "file")
_pv_sel_mask :: proc(ch_idx, count: int) -> []bool {
	mask := make([]bool, count, context.temp_allocator)
	for r in _pv.sel {
		if r.ch == ch_idx && r.key >= 0 && r.key < count do mask[r.key] = true
	}
	return mask
}

// --- Window ---------------------------------------------------------------------------

draw_animation_view :: proc() {
	if !im.Begin(icons.TITLE_ANIMATION, &menu.show_animation, {.NoCollapse}) {
		// Tabbed-away, not closed: the preview keeps running.
		im.End()
		return
	}
	defer im.End()

	owner, a := _pv_target()
	if a == nil {
		_pv.active = false
		im.TextDisabled("Select an object with an Animation component.")
		return
	}
	// Retarget follows selection: the old target's graph and binding
	// belong to the old owner.
	if owner != _pv.owner {
		_pv_teardown()
		_pv_deselect()
		_pv.owner = owner
	}

	clips := _pv_clips(a)
	if len(clips) == 0 {
		_pv.active = false
		im.TextDisabled("The Animation component has no clips.")
		return
	}
	in_list := false
	for c in clips {
		if c == _pv.clip do in_list = true
	}
	if !in_list {
		_pv_teardown()
		_pv_deselect()
		_pv.clip = clips[0]
		_pv.time = 0
	}

	doc, clip := _pv_doc()
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001

	_pv_draw_toolbar(doc, clip, clips, length)
	_pv_advance(clip, length)
	_pv_rec_poll(doc, clip)

	if clip == nil {
		im.TextDisabled("The clip has no document (missing or unreadable .anim).")
		return
	}
	// Undo may have shrunk the clip since the selection was made.
	if _pv.sel_ch >= len(clip.channels) do _pv_deselect()
	if _pv.sel_ch >= 0 && _pv.sel_key >= len(clip.channels[_pv.sel_ch].times) do _pv.sel_key = -1
	_pv_sel_prune(clip)

	// The sheet, then the view tabs under it: the tabs belong to the sheet,
	// not to the transport, so they sit at its bottom edge.
	footer := _pv_sel_valid(clip)
	tabs_h := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y
	body_h := -(tabs_h + (footer ? im.GetFrameHeight() + 8 : 0))
	im.BeginChild("##anim_body", im.Vec2{0, body_h}, {.Borders})
	_pv_draw_sheet(doc, clip)
	im.EndChild()
	_pv_draw_mode_tabs()

	// Delete on the selected key; text input (a drag field being typed into)
	// owns Backspace.
	if _pv_sel_valid(clip) && !im.GetIO().WantTextInput &&
	   im.IsWindowFocused({.ChildWindows}) &&
	   (im.IsKeyPressed(.Delete) || im.IsKeyPressed(.Backspace)) {
		_pv_delete_key(doc, clip)
	}

	if footer && _pv_sel_valid(clip) {
		_pv_draw_key_footer(doc, clip)
	}

	// Push this frame's edits into the engine cache the preview samples from.
	if _pv.sync {
		_pv.sync = false
		if d2, c2 := _pv_doc(); c2 != nil {
			anim.animation_clip_preview(d2.guid, c2^)
		}
	}
}

@(private = "file")
_pv_draw_toolbar :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.Asset_GUID, length: f32) {
	fps := anim.animation_clip_frame_rate(clip)

	// Preview toggle. The pop must match the state at push time — the click
	// flips _pv.active in between.
	tinted := _pv.active
	if tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Preview") do _pv.active = !_pv.active
	if tinted do im.PopStyleColor()
	if im.IsItemHovered({}) do im.SetTooltip("Pose the object from this clip while the window is open")

	// Record: while armed, editing an animated field writes a key at the
	// playhead. Drawn in red like a record light, lit while armed.
	// The record light is red whether armed or not, brighter while armed. The
	// Text push is what colors the glyph the shared button draws.
	im.SameLine()
	rec := _pv.recording
	im.PushStyleColorImVec4(.Text, rec ? im.Vec4{0.95, 0.25, 0.25, 1} : im.Vec4{0.75, 0.35, 0.35, 1})
	armed := widgets.icon_button(icons.ICON_MD_RECORD, "##rec",
		"Record: an edited animated field keys itself at the playhead", active = rec)
	im.PopStyleColor()
	if armed {
		_pv.recording = !_pv.recording
		if _pv.recording {
			_pv.active = true // recording poses the object, as previewing does
			_pv_rec_resync(clip)
		}
	}

	// Transport: start, previous key, play, next key, end.
	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_FIRST_PAGE, "##first", "Go to the start") {
		_pv.time = 0
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_PREV_KEY, "##prevkey", "Previous keyframe") {
		_pv.time = _pv_key_step(clip, _pv.time, back = true)
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(_pv.playing ? icons.ICON_MD_PAUSE : icons.ICON_MD_PLAY_ARROW, "##play", _pv.playing ? "Pause" : "Play the clip") {
		_pv.playing = !_pv.playing
		if _pv.playing do _pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_NEXT_KEY, "##nextkey", "Next keyframe") {
		_pv.time = _pv_key_step(clip, _pv.time, back = false)
		_pv.active = true
	}

	im.SameLine()
	if widgets.icon_button(icons.ICON_MD_LAST_PAGE, "##last", "Go to the end") {
		_pv.time = length
		_pv.active = true
	}

	// The playhead as a frame number, with the clip's frame count beside it.
	im.SameLine()
	im.SetNextItemWidth(58)
	frame := i32(math.round(_pv.time * fps))
	if im.InputInt("##pv_frame", &frame, 0, 0, {.EnterReturnsTrue}) {
		_pv.time = clamp(f32(frame) / fps, 0, length)
		_pv.active = true
	}
	if im.IsItemHovered({}) do im.SetTooltip("Playhead frame")
	im.SameLine()
	im.TextDisabled(fmt.ctprintf("/ %d", i32(math.round(length * fps))))

	if clip != nil && doc != nil {
		// Key the selected property at the playhead.
		im.SameLine()
		im.BeginDisabled(_pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels))
		if widgets.icon_button(icons.ICON_MD_KEYFRAME, "##addkey", "Add a keyframe on the selected property") {
			_pv_add_key(doc, clip, _pv.sel_ch, _pv.time)
		}
		im.EndDisabled()

		im.SameLine()
		if im.Button("Add Property") do im.OpenPopup("##anim_add_prop")
		if im.BeginPopup("##anim_add_prop") {
			_pv_add_prop_object(doc, clip, _pv.owner, "", 0)
			im.EndPopup()
		}

		// Clip picker and Save sit at the right end, away from the transport.
		im.SameLine()
		save_w := im.CalcTextSize(doc.dirty ? "Save *" : "Save").x + im.GetStyle().FramePadding.x * 2
		right := im.GetContentRegionAvail().x - (180 + im.GetStyle().ItemSpacing.x + save_w)
		if right > 0 do im.SetCursorPosX(im.GetCursorPosX() + right)

		im.SetNextItemWidth(180)
		cur := strings.clone_to_cstring(_pv_clip_name(_pv.clip), context.temp_allocator)
		if im.BeginCombo("##pv_clip", cur) {
			for c in clips {
				name := strings.clone_to_cstring(_pv_clip_name(c), context.temp_allocator)
				if im.Selectable(name, c == _pv.clip) && c != _pv.clip {
					_pv_teardown()
					_pv_deselect()
					_pv.clip = c
					_pv.time = 0
				}
			}
			im.EndCombo()
		}
		if im.IsItemHovered({}) do im.SetTooltip("Clip to edit")

		im.SameLine()
		im.BeginDisabled(!doc.dirty)
		if im.Button(doc.dirty ? "Save *" : "Save") {
			if ser.save_to_file(doc.path, doc.data) do doc.dirty = false
		}
		im.EndDisabled()
	} else {
		im.NewLine()
	}
}

// Dopesheet / Curves, as tabs along the bottom of the sheet.
@(private = "file")
_pv_draw_mode_tabs :: proc() {
	if !im.BeginTabBar("##anim_modes", {}) do return
	defer im.EndTabBar()
	// imgui owns which tab is open and _pv.mode follows it. Forcing the open
	// tab from _pv.mode every frame would re-select the current one before a
	// click on the other could take effect.
	for mode in _Anim_Mode {
		if im.BeginTabItem(fmt.ctprintf("%v", mode), nil, {}) {
			_pv.mode = mode
			im.EndTabItem()
		}
	}
}

// The nearest key time before or after `from` across every channel, so the
// transport steps between poses rather than by a fixed amount. Returns `from`
// when there is nothing further in that direction.
@(private = "file")
_pv_key_step :: proc(clip: ^anim.AnimationClip, from: f32, back: bool) -> f32 {
	if clip == nil do return from
	EPS :: f32(1e-5)
	best := from
	found := false
	for &ch in clip.channels {
		for t in ch.times {
			if back {
				if t < from - EPS && (!found || t > best) {
					best = t
					found = true
				}
			} else {
				if t > from + EPS && (!found || t < best) {
					best = t
					found = true
				}
			}
		}
	}
	return best
}

// Advance the playhead while the transport runs, wrapping the way the clip
// itself does so playback matches what the component will do.
@(private = "file")
_pv_advance :: proc(clip: ^anim.AnimationClip, length: f32) {
	if !_pv.playing do return
	_pv.time += gfx.delta_time()
	if _pv.time < length do return
	switch clip != nil ? clip.wrap : anim.Animation_Wrap.Once {
	case .Loop:
		_pv.time -= length * math.floor(_pv.time / length)
	case .Once:
		// Played through: rewind to the first frame and stop, so pressing play
		// again replays from the start instead of sitting on the last frame.
		_pv.time = 0
		_pv.playing = false
	}
}

// --- Record ------------------------------------------------------------------------
//
// Recording needs no hook into the inspector: a channel's live value only
// leaves the shadow when something wrote the field, and scrubbing never does
// (authored values do not move with the playhead). One key per changed
// channel per frame, each its own undo step like any keyframe edit.

@(private = "file")
_pv_rec_resync :: proc(clip: ^anim.AnimationClip) {
	clear(&_pv.rec_shadow)
	if clip == nil do return
	for &ch in clip.channels {
		v, _ := _pv_live_value(&ch)
		append(&_pv.rec_shadow, v)
	}
}

@(private = "file")
_pv_rec_poll :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if !_pv.recording || clip == nil || doc == nil do return
	// A channel added or removed since the last resync invalidates the pairing.
	if len(_pv.rec_shadow) != len(clip.channels) {
		_pv_rec_resync(clip)
		return
	}
	EPS :: f32(1e-6)
	for &ch, i in clip.channels {
		v, ok := _pv_live_value(&ch)
		if !ok do continue
		d := v - _pv.rec_shadow[i]
		if abs(d.x) < EPS && abs(d.y) < EPS && abs(d.z) < EPS && abs(d.w) < EPS do continue
		_pv.rec_shadow[i] = v
		_pv_add_key(doc, clip, i, _pv.time)
	}
}

// A channel's value as the object holds it right now: the transform for a
// transform channel, the resolved field for a property channel.
@(private = "file")
_pv_live_value :: proc(ch: ^anim.Animation_Channel) -> (v: [4]f32, ok: bool) {
	tH, tok := anim._animation_resolve_target(_pv.owner, ch.target)
	if !tok do return {}, false
	if anim.animation_channel_is_property(ch) {
		ptr, kind, leaf, pok := anim._prop_locate(tH, ch.component, ch.field)
		if !pok do return {}, false
		return anim._prop_read(ptr, kind, leaf), true
	}
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return {}, false
	switch ch.path {
	case .Position: v.xyz = t.position
	case .Rotation: v = t.rotation
	case .Scale:    v.xyz = t.scale
	}
	return v, true
}

// The sheet: property rows on the left, the time canvas (ruler + dopesheet
// keys or curves) on the right, one interaction surface each.
@(private = "file")
_pv_draw_sheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	dl := im.GetWindowDrawList()
	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if avail.x < _ANIM_MIN_LEFT_W + widgets.SPLITTER_SIZE + _ANIM_MIN_CANVAS_W {
		im.TextDisabled("Window too narrow.")
		return
	}

	length := max(clip.length, 0.0001)
	// Property column | splitter gap | time canvas.
	left_w := clamp(_anim_left_w, _ANIM_MIN_LEFT_W, avail.x - widgets.SPLITTER_SIZE - _ANIM_MIN_CANVAS_W)
	left_x1 := origin.x + left_w
	x0 := left_x1 + widgets.SPLITTER_SIZE
	x1 := origin.x + avail.x
	// Time axis: pps (pixels per second) is the fit scale times the zoom, so
	// zoom 1 shows the whole clip and no pan is possible.
	if _pv.zoom < 1 do _pv.zoom = 1
	span_px := max(x1 - x0 - 2 * _ANIM_PAD_X, 1)
	pps_fit := span_px / length
	pps := pps_fit * _pv.zoom
	visible := span_px / pps // seconds across the canvas
	_pv.pan = clamp(_pv.pan, 0, max(length - visible, 0))
	tx0 := x0 + _ANIM_PAD_X - _pv.pan * pps // x of t=0

	nrows := len(clip.channels)
	rows_y := origin.y + _ANIM_RULER_H
	body_h: f32
	if _pv.mode == .Dopesheet {
		// Fills the pane rather than stopping at the last track: the empty
		// area below the tracks is where a box selection often starts.
		body_h = max(f32(nrows) * _ANIM_ROW_H, max(avail.y - _ANIM_RULER_H, _ANIM_ROW_H))
	} else {
		body_h = max(f32(nrows)*_ANIM_ROW_H, max(avail.y - _ANIM_RULER_H, 140))
	}

	// --- Zoom and pan on the time axis. Zoom keeps the time under the cursor
	// in place, which is what makes wheel zoom feel anchored.
	{
		mp := im.GetMousePos()
		// Resolved every frame so a gesture times out even while the pointer
		// is elsewhere; only acted on while the canvas is under it.
		wheel_v, wheel_h := widgets.wheel_dominant(&_pv.wheel)
		over_canvas := im.IsWindowHovered(im.HoveredFlags_ChildWindows) && mp.x >= x0 && mp.x <= x1
		if over_canvas {
			if wheel := wheel_v; wheel != 0 {
				t_at := (mp.x - tx0) / pps
				_pv.zoom = clamp(_pv.zoom * math.pow(f32(1.15), wheel), 1, 200)
				new_pps := pps_fit * _pv.zoom
				_pv.pan = t_at + (x0 + _ANIM_PAD_X - mp.x) / new_pps
				pps = new_pps
				visible = span_px / pps
				_pv.pan = clamp(_pv.pan, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _pv.pan * pps
			}
			// Horizontal wheel (a trackpad's sideways swipe) pans, signed the
			// way imgui scrolls its own windows: positive moves the view
			// toward earlier time.
			if wheel_h != 0 {
				step := span_px * 0.15 / pps // a sixth of the view per notch
				_pv.pan = clamp(_pv.pan - wheel_h * step, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _pv.pan * pps
			}
			// Middle-drag pans too, for a mouse without a sideways wheel.
			if im.IsMouseDragging(.Middle, 1) {
				_pv.pan = clamp(_pv.pan - im.GetIO().MouseDelta.x / pps, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _pv.pan * pps
			}
		}
	}

	// Canvas drawing is clipped to its own column: zoomed in, keys and ticks
	// fall outside it and would otherwise paint over the property panel.
	canvas_clip_min := im.Vec2{x0, origin.y}
	canvas_clip_max := im.Vec2{x1, rows_y + body_h}

	// --- Ruler: dragging it scrubs (the only scrub surface).
	im.SetCursorScreenPos(im.Vec2{x0, origin.y})
	im.InvisibleButton("##anim_ruler", im.Vec2{max(x1 - x0, 1), _ANIM_RULER_H})
	if im.IsItemActive() {
		_pv.time = clamp(_pv_snap_time(clip, (im.GetMousePos().x - tx0) / pps), 0, clip.length)
		_pv.active = true
	}
	im.DrawList_AddRectFilled(dl, im.Vec2{x0, origin.y}, im.Vec2{x1, origin.y + _ANIM_RULER_H}, im.GetColorU32(.FrameBg, 0.6))
	steps := [?]f32{0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60}
	step := steps[len(steps) - 1]
	for s in steps {
		if s * pps >= 55 {
			step = s
			break
		}
	}
	tick_col := im.GetColorU32(.TextDisabled)
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	for i in 0 ..= int(length / step) {
		t := f32(i) * step
		tx := tx0 + t * pps
		im.DrawList_AddLine(dl, im.Vec2{tx, origin.y + _ANIM_RULER_H - 6}, im.Vec2{tx, origin.y + _ANIM_RULER_H}, tick_col, 1)
		im.DrawList_AddText(dl, im.Vec2{tx + 3, origin.y + 3}, tick_col, fmt.ctprintf("%.2f", t))
	}
	im.DrawList_PopClipRect(dl)

	// --- Rows surface (left panel + canvas share it; hit-tested by x). It
	// spans the splitter gap too: AllowOverlap lets the splitter, submitted
	// last, take the pointer there.
	im.SetCursorScreenPos(im.Vec2{origin.x, rows_y})
	im.SetNextItemAllowOverlap()
	im.InvisibleButton("##anim_sheet", im.Vec2{avail.x, body_h})
	hovered := im.IsItemHovered()
	mp := im.GetMousePos()
	row_at := hovered ? int((mp.y - rows_y) / _ANIM_ROW_H) : -1

	// Left panel rows (both modes: this is where curves pick their channel).
	im.DrawList_PushClipRect(dl, im.Vec2{origin.x, rows_y}, im.Vec2{left_x1, rows_y + body_h}, true)
	for &ch, i in clip.channels {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if i == _pv.sel_ch {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.Header, 0.7))
		} else if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		label, resolved := _pv_ch_label(&ch)
		// Missing-binding yellow: the channel's component or field no
		// longer resolves — it samples but never applies.
		col := resolved ? im.GetColorU32(.Text) : im.GetColorU32ImVec4(im.Vec4{0.95, 0.83, 0.30, 1})
		im.DrawList_AddText(dl, im.Vec2{origin.x + 6, ry + 3}, col, label)
	}
	im.DrawList_PopClipRect(dl)

	// Right-click a row: channel operations.
	if hovered && mp.x < x0 && row_at >= 0 && row_at < len(clip.channels) &&
	   im.IsMouseClicked(.Right) {
		_pv.sel_ch = row_at
		_pv.sel_key = -1
		im.OpenPopup("##anim_ch_ctx")
	}
	if im.BeginPopup("##anim_ch_ctx") {
		if im.MenuItem("Remove Property") && _pv.sel_ch >= 0 && _pv.sel_ch < len(clip.channels) {
			_pv_edit_begin(doc)
			_pv_channel_remove(clip, _pv.sel_ch)
			_pv_deselect()
			_pv_edit_commit(doc)
		}
		im.EndPopup()
	}

	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	if _pv.mode == .Dopesheet {
		_pv_sheet_dopesheet(doc, clip, dl, origin, rows_y, body_h, x0, x1, tx0, pps, hovered, mp, row_at)
	} else {
		_pv_sheet_curves(doc, clip, dl, rows_y, body_h, x0, x1, tx0, pps, mp, row_at)
	}
	im.DrawList_PopClipRect(dl)

	// Playhead over everything, inside the canvas column.
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	px := tx0 + clamp(_pv.time, 0, length) * pps
	head_col := im.GetColorU32ImVec4(im.Vec4{0.92, 0.28, 0.28, 1})
	im.DrawList_AddLine(dl, im.Vec2{px, origin.y}, im.Vec2{px, rows_y + body_h}, head_col, 1)
	im.DrawList_AddTriangleFilled(dl, im.Vec2{px - 5, origin.y}, im.Vec2{px + 5, origin.y}, im.Vec2{px, origin.y + 8}, head_col)
	im.DrawList_PopClipRect(dl)

	// Shared drag update/commit (a drag started in either mode).
	if _pv.drag_key {
		if !_pv_sel_valid(clip) || len(_pv.sel) != len(_pv.drag_t0) {
			// A key vanished mid-drag, so there is no edit to record.
			_pv.drag_key = false
			undo.edit_session_abort(&_pv_session)
		} else if im.IsMouseDown(.Left) {
			// One delta for the whole selection, snapped, then clamped by the
			// tightest neighbour bound among the dragged keys so none of them
			// can cross another and reorder the channel.
			want := _pv_snap_time(clip, (mp.x - tx0) / pps) - _pv.drag_from
			lo_d, hi_d := -max(f32), max(f32)
			for r, i in _pv.sel {
				ch := &clip.channels[r.ch]
				mask := _pv_sel_mask(r.ch, len(ch.times))
				lo, hi := anim.animation_key_bounds(ch.times[:], mask, r.key, clip.length)
				lo_d = max(lo_d, lo - _pv.drag_t0[i])
				hi_d = min(hi_d, hi - _pv.drag_t0[i])
			}
			d := clamp(want, lo_d, hi_d)
			for r, i in _pv.sel {
				clip.channels[r.ch].times[r.key] = _pv.drag_t0[i] + d
			}
			if _pv.drag_comp >= 0 {
				// Curves: y edits the grabbed component's value on the primary
				// key only — the others have their own values to keep.
				ch := &clip.channels[_pv.sel_ch]
				ch.values[_pv.sel_key][_pv.drag_comp] = _pv_curve_y_to_v(mp.y, rows_y, body_h)
			}
			_pv_mark_edited(doc)
		} else {
			ch := &clip.channels[_pv.sel_ch]
			if ch.path == .Rotation && _pv.drag_comp >= 0 do _pv_normalize_rot_key(ch, _pv.sel_key)
			_pv_edit_commit(doc)
			_pv.drag_key = false
		}
	}

	// Key context menu (opened by the mode-specific right-click handling).
	if im.BeginPopup("##anim_key_ctx") {
		can_delete := _pv_sel_valid(clip)
		label: cstring = len(_pv.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_pv.sel)) : "Delete Key"
		if im.MenuItem(label, nil, false, can_delete) do _pv_delete_key(doc, clip)
		im.EndPopup()
	}

	// Splitter between the property column and the canvas. Submitted LAST:
	// the mode handlers above query the sheet button as the last item, and a
	// later item is what wins the pointer over the AllowOverlap sheet.
	canvas_w := x1 - x0
	im.SetCursorScreenPos(im.Vec2{left_x1, origin.y})
	if widgets.splitter("##anim_split", true, &left_w, &canvas_w, _ANIM_MIN_LEFT_W, _ANIM_MIN_CANVAS_W) {
		_anim_left_w = left_w
	}
}

// --- Dopesheet ------------------------------------------------------------------------

@(private = "file")
_pv_key_hit_x :: proc(ch: ^anim.Animation_Channel, mx, tx0, pps: f32) -> int {
	best := -1
	best_d := _ANIM_HIT
	for t, k in ch.times {
		d := abs(tx0 + t * pps - mx)
		if d < best_d {
			best_d = d
			best = k
		}
	}
	return best
}

@(private = "file")
_pv_sheet_dopesheet :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	origin: im.Vec2,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	hovered: bool,
	mp: im.Vec2,
	row_at: int,
) {
	// Row stripes + keys.
	for &ch, i in clip.channels {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		ky := ry + _ANIM_ROW_H * 0.5
		for t, k in ch.times {
			kx := tx0 + t * pps
			sel := _pv_sel_has(i, k)
			col := sel ? im.GetColorU32(.CheckMark) : im.GetColorU32(.Text)
			r := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
			im.DrawList_AddQuadFilled(dl,
				im.Vec2{kx, ky - r}, im.Vec2{kx + r, ky},
				im.Vec2{kx, ky + r}, im.Vec2{kx - r, ky}, col)
		}
	}

	valid_row := row_at >= 0 && row_at < len(clip.channels)

	if im.IsItemActivated() {
		in_canvas := mp.x >= x0
		k := -1
		if in_canvas && valid_row do k = _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps)
		switch {
		case k >= 0 && _pv_additive():
			// Add to or drop from the selection, no drag: a modifier click is
			// for building a set, not moving it.
			_pv_sel_toggle(row_at, k)
		case k >= 0:
			// Dragging a key that is already selected moves the whole
			// selection; grabbing an unselected one selects just it.
			if !_pv_sel_has(row_at, k) do _pv_sel_set(row_at, k)
			_pv.sel_ch = row_at
			_pv.sel_key = k
			_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = -1)
		case in_canvas:
			// Empty canvas, on a track row or below the last one: rubber-band
			// a new selection. The row under the press only sets the channel
			// when there is one, so a band started below the tracks leaves
			// the current channel alone.
			if valid_row do _pv.sel_ch = row_at
			_pv.sel_key = -1
			clear(&_pv.sel)
			_pv.box = true
			_pv.box_from = mp
		case valid_row:
			// Left panel: pick the channel.
			_pv.sel_ch = row_at
			_pv.sel_key = -1
			clear(&_pv.sel)
		}
	}
	if im.IsItemClicked(.Right) && valid_row {
		if k := _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps); k >= 0 && mp.x >= x0 {
			// Right-clicking outside the selection retargets it, so the menu
			// always acts on what is under the cursor.
			if !_pv_sel_has(row_at, k) do _pv_sel_set(row_at, k)
			_pv.sel_ch = row_at
			_pv.sel_key = k
			im.OpenPopup("##anim_key_ctx")
		}
	}
	// Double-click on empty canvas: add a key there (sampled, shape-preserving).
	if hovered && valid_row && mp.x >= x0 && im.IsMouseDoubleClicked(.Left) {
		if _pv_key_hit_x(&clip.channels[row_at], mp.x, tx0, pps) < 0 {
			_pv.box = false // the press that opened the band was this click
			_pv_add_key(doc, clip, row_at, _pv_snap_time(clip, (mp.x - tx0) / pps))
		}
	}

	// --- Box select: every key inside the band, across channels.
	if _pv.box {
		rmin := im.Vec2{min(_pv.box_from.x, mp.x), min(_pv.box_from.y, mp.y)}
		rmax := im.Vec2{max(_pv.box_from.x, mp.x), max(_pv.box_from.y, mp.y)}
		im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32(.Header, 0.35))
		im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32(.CheckMark))

		clear(&_pv.sel)
		for &ch, i in clip.channels {
			ky := rows_y + f32(i) * _ANIM_ROW_H + _ANIM_ROW_H * 0.5
			if ky < rmin.y || ky > rmax.y do continue
			for t, k in ch.times {
				kx := tx0 + t * pps
				if kx < rmin.x || kx > rmax.x do continue
				append(&_pv.sel, _Key_Ref{i, k})
			}
		}
		// Primary is the first key the band caught, so the value footer has
		// something to edit.
		if len(_pv.sel) > 0 {
			_pv.sel_ch = _pv.sel[0].ch
			_pv.sel_key = _pv.sel[0].key
		} else {
			_pv.sel_key = -1
		}
		if !im.IsMouseDown(.Left) do _pv.box = false
	}
}

// Opens the undo session for a key drag and records where every selected key
// started, so the move is one delta applied to the group.
@(private = "file")
_pv_drag_begin :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, from: f32, comp: int) {
	_pv_edit_begin(doc)
	_pv.drag_key = true
	_pv.drag_comp = comp
	_pv.drag_from = _pv_snap_time(clip, from)
	clear(&_pv.drag_t0)
	for r in _pv.sel do append(&_pv.drag_t0, clip.channels[r.ch].times[r.key])
}

// --- Curves ---------------------------------------------------------------------------

// Value range of the curve area this frame (set during draw, read by the drag
// update). Range follows the selected channel's keys with 10% padding.
@(private = "file")
_curve_vmin, _curve_vmax: f32

@(private = "file")
_pv_curve_v_to_y :: proc(v, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return rows_y + 6 + (1 - (v - _curve_vmin) / span) * (body_h - 12)
}

@(private = "file")
_pv_curve_y_to_v :: proc(y, rows_y, body_h: f32) -> f32 {
	span := max(_curve_vmax - _curve_vmin, 0.0001)
	return _curve_vmin + (1 - (y - rows_y - 6) / max(body_h - 12, 1)) * span
}

@(private = "file")
_pv_sheet_curves :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	mp: im.Vec2,
	row_at: int,
) {
	// Left-panel click selects the channel whose curves show.
	if im.IsItemActivated() && mp.x < x0 && row_at >= 0 && row_at < len(clip.channels) {
		_pv.sel_ch = row_at
		_pv.sel_key = -1
		clear(&_pv.sel)
	}

	if _pv.sel_ch < 0 || _pv.sel_ch >= len(clip.channels) {
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "Select a property to edit its curves.")
		return
	}
	ch := &clip.channels[_pv.sel_ch]
	ncomp := _pv_ch_ncomp(ch)

	// Freeze the value range while dragging — a range that follows the edited
	// value makes the curve chase the cursor.
	if !_pv.drag_key {
		vmin, vmax := max(f32), min(f32)
		for v in ch.values {
			for c in 0 ..< ncomp {
				vmin = min(vmin, v[c])
				vmax = max(vmax, v[c])
			}
		}
		if vmax < vmin {
			vmin, vmax = 0, 1
		}
		if vmax - vmin < 0.001 {
			vmin -= 0.5
			vmax += 0.5
		}
		pad := (vmax - vmin) * 0.1
		_curve_vmin, _curve_vmax = vmin - pad, vmax + pad
	}

	// Value grid: min, max and zero when visible.
	grid_col := im.GetColorU32(.Border, 0.6)
	for v in ([3]f32{_curve_vmin, _curve_vmax, 0}) {
		if v < _curve_vmin || v > _curve_vmax do continue
		gy := _pv_curve_v_to_y(v, rows_y, body_h)
		im.DrawList_AddLine(dl, im.Vec2{x0, gy}, im.Vec2{x1, gy}, grid_col, 1)
		im.DrawList_AddText(dl, im.Vec2{x0 + 4, gy - 14}, im.GetColorU32(.TextDisabled), fmt.ctprintf("%.3g", v))
	}

	// One polyline per component, sampled (slerp and step are not linear
	// between keys), keys as squares on top.
	im.DrawList_PushClipRect(dl, im.Vec2{x0, rows_y}, im.Vec2{x1, rows_y + body_h}, true)
	comp_cols := _ANIM_COMP_COLS
	for c in 0 ..< ncomp {
		col := im.GetColorU32ImVec4(comp_cols[c])
		pts := make([dynamic]im.Vec2, context.temp_allocator)
		for x := tx0; x <= x1 - _ANIM_PAD_X + 3; x += 3 {
			v := anim._animation_channel_sample(ch, (x - tx0) / pps)
			append(&pts, im.Vec2{x, _pv_curve_v_to_y(v[c], rows_y, body_h)})
		}
		if len(pts) >= 2 {
			im.DrawList_AddPolyline(dl, raw_data(pts[:]), i32(len(pts)), col, 1.5)
		}
		for t, k in ch.times {
			kx := tx0 + t * pps
			ky := _pv_curve_v_to_y(ch.values[k][c], rows_y, body_h)
			sel := k == _pv.sel_key && c == _pv.drag_comp
			r := sel ? f32(4) : f32(3)
			im.DrawList_AddRectFilled(dl, im.Vec2{kx - r, ky - r}, im.Vec2{kx + r, ky + r}, sel ? im.GetColorU32(.CheckMark) : col)
		}
	}
	im.DrawList_PopClipRect(dl)

	// Press on a key square: drag edits (time, value[comp]).
	if im.IsItemActivated() && mp.x >= x0 {
		best_k, best_c := -1, -1
		best_d := _ANIM_HIT
		for t, k in ch.times {
			kx := tx0 + t * pps
			for c in 0 ..< ncomp {
				ky := _pv_curve_v_to_y(ch.values[k][c], rows_y, body_h)
				d := max(abs(kx - mp.x), abs(ky - mp.y))
				if d < best_d {
					best_d = d
					best_k, best_c = k, c
				}
			}
		}
		if best_k >= 0 {
			if _pv_additive() {
				_pv_sel_toggle(_pv.sel_ch, best_k)
			} else {
				// As in the dopesheet: dragging a selected key moves the
				// group, an unselected one becomes the selection.
				if !_pv_sel_has(_pv.sel_ch, best_k) do _pv_sel_set(_pv.sel_ch, best_k)
				_pv.sel_key = best_k
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = best_c)
			}
		} else {
			_pv.sel_key = -1
			clear(&_pv.sel)
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		if k := _pv_key_hit_x(ch, mp.x, tx0, pps); k >= 0 {
			if !_pv_sel_has(_pv.sel_ch, k) do _pv_sel_set(_pv.sel_ch, k)
			_pv.sel_key = k
			im.OpenPopup("##anim_key_ctx")
		}
	}
}

// --- Selected-key footer ----------------------------------------------------------------

@(private = "file")
_pv_draw_key_footer :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	ch := &clip.channels[_pv.sel_ch]
	k := _pv.sel_key

	im.AlignTextToFramePadding()
	im.TextUnformatted(fmt.ctprintf("Key %d   t", k))
	im.SameLine()
	im.SetNextItemWidth(70)
	lo, hi := _pv_drag_time_bounds(ch, k, clip.length)
	_pv_field_undo(doc, clip, im.DragFloat("##anim_key_t", &ch.times[k], 0.002, lo, hi, "%.3f"))

	ncomp := _pv_ch_ncomp(ch)
	comp_names := [4]cstring{"x", "y", "z", "w"}
	for c in 0 ..< ncomp {
		im.SameLine()
		im.TextUnformatted(comp_names[c])
		im.SameLine()
		im.SetNextItemWidth(70)
		_pv_field_undo(doc, clip, im.DragFloat(fmt.ctprintf("##anim_key_v%d", c), &ch.values[k][c], 0.01))
	}

	im.SameLine()
	im.BeginDisabled(len(ch.times) <= 1)
	if im.Button(len(_pv.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_pv.sel)) : "Delete Key") {
		_pv_delete_key(doc, clip)
	}
	im.EndDisabled()
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// A fingerprint of the component's authored clip set, so the preview graph
// rebuilds when layers/clips are edited while previewing.
@(private = "file")
_pv_authored_sig :: proc(a: ^anim.Animation) -> u64 {
	sig := u64(0xcbf29ce484222325)
	_pv_sig_mix(&sig, a.clip)
	for &l in a.layers {
		sig ~= 0x9e37
		for c in l.clips do _pv_sig_mix(&sig, c)
	}
	return sig
}

@(private = "file")
_pv_sig_mix :: proc(sig: ^u64, g: engine.Asset_GUID) {
	// Asset_GUID is a distinct [16]u8: transmute, not cast — an array type
	// conversion is not a cast in Odin.
	bytes := transmute([16]u8)g
	for b in bytes do sig^ = (sig^ ~ u64(b)) * 0x100000001b3
}

// The scrub preview evaluates the component's FULL authored graph — layer
// mixer root, one mixer per authored layer, every clip a leaf — with the
// scrubbed clip at weight 1 and everything else at 0. The zero-weight nodes
// cost nothing (the evaluator skips them) and change nothing in the pose,
// but the preview path is the graph the component actually plays, and the
// Playable Graph visualizer shows the real topology with live weights.
@(private = "file")
_pv_build_graph :: proc(a: ^anim.Animation) {
	anim.playable_graph_init(&_pv.graph)
	anim.animation_binding_init(&_pv.binding, _pv.owner)
	_pv.graph.root = anim.playable_add(&_pv.graph, anim.Layer_Mixer_Playable{})
	_pv.node = {}

	n_layers := max(len(a.layers), 1)
	for li in 0 ..< n_layers {
		mixer := anim.playable_add(&_pv.graph, anim.Mixer_Playable{})
		anim.playable_connect(&_pv.graph, _pv.graph.root, mixer, 1)

		clips := make([dynamic]engine.Asset_GUID, context.temp_allocator)
		if li == 0 do _pv_clips_add(&clips, a.clip)
		if li < len(a.layers) {
			for c in a.layers[li].clips do _pv_clips_add(&clips, c)
		}
		for c in clips {
			node := anim.playable_add(&_pv.graph, anim.Clip_Playable{clip = c})
			w := f32(0)
			if c == _pv.clip && _pv.node == {} {
				_pv.node = node
				w = 1
			}
			anim.playable_connect(&_pv.graph, mixer, node, w)
		}
	}
	_pv.graph_sig = _pv_authored_sig(a)
	_pv.ready = true
}

// Apply the preview pose for this frame's scene/game render. Runs in the main
// loop after the window UI set the scrub state, right before the world renders.
animation_preview_apply :: proc() {
	if !_pv.active do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) || _pv.clip == {} {
		_pv.active = false
		return
	}
	_, a := engine.transform_get_comp(_pv.owner, anim.Animation)
	if a == nil {
		_pv.active = false
		return
	}
	clip, ok := anim.animation_clip_load(_pv.clip)
	if !ok do return

	if _pv.ready && _pv.graph_sig != _pv_authored_sig(a) do _pv_teardown()
	if !_pv.ready do _pv_build_graph(a)
	if n := anim.playable_node(&_pv.graph, _pv.node); n != nil {
		n.time = clamp(_pv.time, 0, clip.length)
	}

	anim.animation_binding_refresh_defaults(&_pv.binding)
	pose := anim.playable_graph_evaluate(&_pv.graph, &_pv.binding)
	anim.animation_pose_apply(&_pv.binding, pose)
	_pv.applied = true
}

// Restore the authored pose after the scene/game render. The world spends the
// rest of the frame — saves, undo, inspector — at authored values.
animation_preview_restore :: proc() {
	if !_pv.applied do return
	_pv.applied = false
	anim.animation_binding_write_defaults(&_pv.binding)
}
