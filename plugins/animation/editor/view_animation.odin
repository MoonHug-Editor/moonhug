package animation_editor

// Animation window — clip authoring on the PlayableGraph scrub path
// (plugins/animation/docs/AnimationComponent.md steps 5+6): scrub preview plus dopesheet and curve
// editing for the clips on the selected object's Animation component.
//
// PREVIEW (step 5): never leaks into saved data. Each frame:
//   1. the window UI sets the scrub state (clip, time, on/off),
//   2. animation_preview_apply refreshes the binding defaults from the live
//      transforms, evaluates the clip at the scrub time and applies the pose,
//   3. the scene and game views render the posed world,
//   4. animation_preview_restore writes the defaults back.
// Outside that render window the world holds authored values, so saves and
// undo are untouched by construction — there is no preview state to revert
// when preview ends, the target dies or its scene unloads. The inspector
// shows the preview's values through inspector.driven_provider (record.odin).
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
import engine "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"
import "moonhug:editor/session"
import "moonhug:editor/undo"
import "moonhug:editor/preview"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:editor/icons"

@(private = "file") _ANIM_MIN_LEFT_W :: f32(210) // a vec4 row's value fields plus the start of its name
@(private = "file") _ANIM_MIN_CANVAS_W :: f32(80)
@(private = "file") _ANIM_DRAG_PX :: f32(4) // a press that moves less is a click
@(private = "file") _ANIM_RULER_H :: f32(22) // minimum: the band grows to a frame height
@(private = "file") _ANIM_ROW_H :: f32(20)
@(private = "file") _ANIM_PAD_X :: f32(10) // time gutter inside the canvas
@(private = "file") _ANIM_KEY_R :: f32(4)  // key diamond half-size
@(private = "file") _ANIM_HIT :: f32(6)    // key hit-test radius
@(private = "file") _ANIM_VAL_W :: f32(42)  // one value field of a row
@(private = "file") _ANIM_VAL_GAP :: f32(2)
@(private = "file") _ANIM_INDENT :: f32(14) // a property row's indent under its Object row
@(private = "file") _ANIM_ARROW_W :: f32(10) // an Object row's collapse arrow
@(private = "file") _ANIM_TAN_LEN :: f32(40) // a tangent handle's distance from its key, in pixels
@(private = "file") _ANIM_TAN_R :: f32(3.5)  // a tangent handle's circle radius
// Missing-binding yellow: a row whose target, component or field no longer
// resolves. It samples but never applies.
@(private = "file") _ANIM_WARN_COL :: im.Vec4{0.95, 0.83, 0.30, 1}

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

@(private)
_pv: struct {
	active:  bool, // preview on: the world renders the scrubbed pose
	applied: bool, // pose applied this frame, restore pending
	owner:   engine.Transform_Handle, // the Animation component's transform
	clip:    engine.PPtr,
	time:    f32,
	graph:     anim.Playable_Graph, // the component's FULL authored graph
	node:      anim.Playable_Handle, // the scrubbed clip's node (weight 1)
	graph_sig: u64, // authored clip set the graph was built from
	ready:     bool,

	// STATE mode: the States tree is previewing an authored state rather than
	// the window scrubbing a clip. Both drive this one preview, so they cannot
	// pose the object at the same time — entry 0 means clip-scrub mode.
	//
	// `entry_clock` is seconds for a clip state and a normalized phase for a
	// blend, matching what each kind runs on at playback.
	entry:       i32,
	entry_kids:  [dynamic]anim.Animation_Blend_Child, // a blend's children, sorted by position
	entry_top:   anim.Playable_Handle, // what hangs from the layer mixer
	entry_layer: anim.Playable_Handle,
	entry_clock: f32,
	entry_done:  bool,

	playing:   bool, // transport running: time advances every frame
	recording: bool, // armed: an edit of an animatable field keys it at the playhead (record.odin)

	sync:      bool, // document edited this frame -> push to the clip cache
}

ANIMATION_VIEW :: "Animation"

// One Animation copy's own state: how it shows the clip. The clip, the
// playhead and the transport are the preview's (_pv), shared by every copy,
// since the world holds one pose.
@(private = "file")
_Anim_View :: struct {
	left_w:    f32, // property column width, dragged via the pane splitter
	// Set by the sheet each frame: the pointer is over the time canvas, where
	// the wheel zooms. Read by the body child, which scrolls on the wheel only
	// when it is false.
	over_canvas: bool,
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
	drag_press: im.Vec2, // mouse at the press: a drag moves keys only past _ANIM_DRAG_PX
	drag_live: bool, // the press moved far enough to be a drag, not a click
	drag_t0:   [dynamic]f32, // each selected key's time then, parallel to sel
	// Curves: a tangent handle drag in progress (undo session open), on key
	// tan_key of the selected channel, lane tan_comp, the out handle when
	// tan_out, else the in handle.
	drag_tan:  bool,
	tan_key:   int,
	tan_comp:  int,
	tan_out:   bool,
	// Box select in progress, and where it started (screen space).
	box:       bool,
	box_from:  im.Vec2,
	// Time-axis view, the sequencer's model: zoom is a multiple of the scale
	// that fits the whole clip, so 1 is "fit" and pan is then pinned to 0.
	// pan is the time at the canvas's left edge.
	zoom:      f32,
	pan:       f32,
	wheel:     widgets.Wheel_Lock, // one wheel axis per gesture
	// Targets whose Object row is collapsed (sheet_rows.odin). Keys are clones
	// under the default allocator, freed with the view. Not persisted.
	collapsed: map[string]bool,
	// The Object row path field (retargeting). path_target is the target being
	// edited and ctx_target the Object row the context menu opened on, both
	// clones under the default allocator. path_wait counts the frames left for
	// the field to take focus, 0 once it has it.
	path_edit:   bool,
	path_target: string,
	path_buf:    [256]u8,
	path_wait:   int,
	ctx_target:  string,
}

_ANIM_VIEW_INIT :: _Anim_View{left_w = 300, sel_ch = -1, sel_key = -1}

// The copy being drawn, and outside a draw the copy clicked in last. With no
// copy open it points at a spare state, so a write lands nowhere.
@(private = "file")
_av: ^_Anim_View = &_av_none

@(private = "file")
_av_none := _ANIM_VIEW_INIT

@(private = "file")
_anim_view :: proc(w: ^wnd.Window) -> ^_Anim_View {
	return wnd.state(w, _ANIM_VIEW_INIT)
}

@(private = "file")
_anim_view_free :: proc(av: ^_Anim_View) {
	context.allocator = runtime.default_allocator()
	delete(av.sel)
	delete(av.drag_t0)
	for k in av.collapsed do delete(k)
	delete(av.collapsed)
	delete(av.path_target)
	delete(av.ctx_target)
	av.sel = nil
	av.drag_t0 = nil
	av.collapsed = nil
	av.path_edit = false
	av.path_target = ""
	av.ctx_target = ""
}

// Replaces a view-owned string with a clone of `s`.
@(private = "file")
_pv_view_str_set :: proc(dst: ^string, s: string) {
	delete(dst^, runtime.default_allocator())
	dst^ = strings.clone(s, runtime.default_allocator())
}

// Collapses or expands `target`'s Object row in the current copy.
@(private = "file")
_pv_collapse_toggle :: proc(target: string) {
	context.allocator = runtime.default_allocator()
	if target in _av.collapsed {
		k, _ := delete_key(&_av.collapsed, target)
		delete(k)
		return
	}
	if _av.collapsed == nil do _av.collapsed = make(map[string]bool)
	_av.collapsed[strings.clone(target)] = true
}

// Expands `target`'s Object row in the current copy, so a channel just added
// under it shows.
@(private = "file")
_pv_collapse_clear :: proc(target: string) {
	if target in _av.collapsed do _pv_collapse_toggle(target)
}

animation_view_closed :: proc(w: ^wnd.Window) {
	av := (^_Anim_View)(w.data)
	if av == nil do return
	if _av == av do _av = &_av_none
	_anim_view_free(av)
	free(av, runtime.default_allocator())
	w.data = nil
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
animation_preview_install :: proc() {
	preview.register({apply = animation_preview_apply, restore = animation_preview_restore})
	preview.register_frame({frame = _animation_views_frame})
}

// The preview's own frame, once per frame before the views draw: with an
// Animation copy open it follows the target and runs the transport, whether
// or not a copy is visible, and with none open the preview ends.
@(private = "file")
_animation_views_frame :: proc() {
	if wnd.is_open(ANIMATION_VIEW) {
		_animation_frame()
	} else {
		animation_preview_stop()
	}
}

@(phase={key=engine.Phase.EditorShutdown, order=1, mode=Editor})
animation_views_shutdown :: proc() {
	shutdown_animation_view()
	shutdown_animation_inspector()
}

shutdown_animation_view :: proc() {
	_pv_teardown()
	_record_note_clear()
	_anim_view_free(&_av_none)
}

// Closing the last Animation copy ends the preview.
animation_preview_stop :: proc() {
	_pv_preview_off()
}

// Stop previewing, and stop everything that only makes sense while previewing.
// A running transport with nothing posed is a playhead sweeping the sheet for
// no reason, and it surprises you later: turning preview back on resumes
// mid-clip, and the button sat on Pause the whole time. A previewed STATE is
// the same — it poses through this preview, so it ends with it.
@(private)
_pv_preview_off :: proc() {
	_pv.active = false
	_pv.playing = false
	_pv.recording = false
	_pv.entry = 0
	_record_note_clear()
}

// The scrub graph's single output binding.
@(private = "file")
_pv_binding :: proc() -> ^anim.Animation_Binding {
	o := anim.graph_output(&_pv.graph)
	return o != nil ? &o.binding : nil
}

@(private)
_pv_teardown :: proc() {
	if _pv.ready {
		anim.playable_graph_destroy(&_pv.graph)
	}
	_pv.ready = false
	_pv.node = {}
	// These name nodes in the graph just destroyed.
	clear(&_pv.entry_kids)
	_pv.entry_top = {}
	_pv.entry_layer = {}
}

// --- Previewing an authored STATE (the inspector's States tree) -------------
//
// The tree plays a state in edit mode through the window's preview rather than
// its own: one preview means one poser, so a scrub and a state can never fight
// over the same object. Entering state mode ends any scrub, and picking a clip
// in the window ends the state.

// Play an authored state on `owner` in edit mode, from its start.
preview_play_entry :: proc(owner: engine.Transform_Handle, id: i32) {
	if _pv.owner != owner {
		_pv_deselect_all()
		_pv.owner = owner
		_pv.clip = {}
	}
	_pv_teardown()
	_pv.entry = id
	_pv.entry_clock = 0
	_pv.entry_done = false
	_pv.playing = false // the transport drives the clip scrub, not this
	_pv.active = true
}

// The state being previewed on `owner`, or 0.
preview_entry :: proc(owner: engine.Transform_Handle) -> i32 {
	if !_pv.active || _pv.owner != owner do return 0
	return _pv.entry
}

preview_stop_entry :: proc() {
	if _pv.entry == 0 do return
	_pv_preview_off()
	_pv_teardown()
}

// Clears every copy's key selection: the clip they select in changed.
@(private = "file")
_pv_deselect_all :: proc() {
	prev := _av
	defer _av = prev
	for w in wnd.instances(ANIMATION_VIEW) {
		_av = _anim_view(w)
		_pv_deselect()
	}
}

_pv_deselect :: proc() {
	_av.sel_ch = -1
	_av.sel_key = -1
	clear(&_av.sel)
	_av.drag_key = false
	_av.drag_tan = false
	_av.box = false
}

// --- Key selection ---------------------------------------------------------------------

// The selection is cross-frame state, so it allocates from the default
// allocator whatever the caller's context holds (Record keys under the
// document allocator).
@(private = "file")
_pv_sel_pin :: proc() {
	if _av.sel.allocator.procedure == nil do _av.sel.allocator = runtime.default_allocator()
}

// Replace the selection with one key, which becomes primary.
@(private = "file")
_pv_sel_set :: proc(ch, key: int) {
	_pv_sel_pin()
	clear(&_av.sel)
	append(&_av.sel, _Key_Ref{ch, key})
	_av.sel_ch = ch
	_av.sel_key = key
}

// Add a key to the selection, or drop it when already there (additive click).
// The clicked key becomes primary either way it stays selected.
@(private = "file")
_pv_sel_toggle :: proc(ch, key: int) {
	for r, i in _av.sel {
		if r.ch == ch && r.key == key {
			ordered_remove(&_av.sel, i)
			// The primary went with it: fall back to any remaining key.
			if _av.sel_ch == ch && _av.sel_key == key {
				if len(_av.sel) > 0 {
					_av.sel_ch = _av.sel[0].ch
					_av.sel_key = _av.sel[0].key
				} else {
					_av.sel_key = -1
				}
			}
			return
		}
	}
	_pv_sel_pin()
	append(&_av.sel, _Key_Ref{ch, key})
	_av.sel_ch = ch
	_av.sel_key = key
}

@(private = "file")
_pv_sel_has :: proc(ch, key: int) -> bool {
	for r in _av.sel {
		if r.ch == ch && r.key == key do return true
	}
	return false
}

// Whether every key of `keys` is selected.
@(private = "file")
_pv_sel_has_all :: proc(keys: []Sheet_Key) -> bool {
	for k in keys {
		if !_pv_sel_has(k.ch, k.key) do return false
	}
	return true
}

// Replace the selection with `keys` (an Object row's keys at one time). The
// first becomes primary.
@(private = "file")
_pv_sel_set_keys :: proc(keys: []Sheet_Key) {
	assert(len(keys) > 0, "an Object row summary key stands for at least one key")
	_pv_sel_pin()
	clear(&_av.sel)
	for k in keys do append(&_av.sel, _Key_Ref{k.ch, k.key})
	_av.sel_ch = keys[0].ch
	_av.sel_key = keys[0].key
}

// Additive click on an Object row summary key: drops its keys when all of them
// are selected, else adds the missing ones. The first of them becomes primary
// when they stay selected.
@(private = "file")
_pv_sel_toggle_keys :: proc(keys: []Sheet_Key) {
	assert(len(keys) > 0, "an Object row summary key stands for at least one key")
	if _pv_sel_has_all(keys) {
		for k in keys do _pv_sel_toggle(k.ch, k.key)
		return
	}
	_pv_sel_pin()
	for k in keys {
		if !_pv_sel_has(k.ch, k.key) do append(&_av.sel, _Key_Ref{k.ch, k.key})
	}
	_av.sel_ch = keys[0].ch
	_av.sel_key = keys[0].key
}

// Drop selection entries a document edit has invalidated (a channel or key
// removed by undo, or by deleting keys).
@(private = "file")
_pv_sel_prune :: proc(clip: ^anim.AnimationClip) {
	for i := len(_av.sel) - 1; i >= 0; i -= 1 {
		r := _av.sel[i]
		if r.ch < 0 || r.ch >= len(clip.channels) || r.key < 0 || r.key >= len(clip.channels[r.ch].times) {
			ordered_remove(&_av.sel, i)
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
	tH := engine.inspector_inspected_selection()
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

// Every clip reachable from the component: the default clip plus every clip
// entry on every layer, blend children included — a clip inside a blend is
// still a clip you edit here. Deduplicated, temp-allocated.
@(private = "file")
_pv_clips :: proc(a: ^anim.Animation) -> []engine.PPtr {
	clips := make([dynamic]engine.PPtr, context.temp_allocator)
	_pv_clips_add(&clips, a.clip)
	for &l in a.layers {
		for &e in l.entries {
			if c, is_clip := e.kind.(anim.Animation_Entry_Clip); is_clip do _pv_clips_add(&clips, c.clip)
		}
	}
	return clips[:]
}

@(private = "file")
_pv_clips_add :: proc(clips: ^[dynamic]engine.PPtr, g: engine.PPtr) {
	if g == {} do return
	for c in clips^ {
		if c == g do return
	}
	append(clips, g)
}

// Shared with the Playable Graph visualizer's clip node labels.
@(private)
_pv_clip_name :: proc(g: engine.PPtr) -> string {
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g.guid)); ok {
		if g.local_id == 0 do return filepath.stem(path)
		for c in engine.mesh_clips(g.guid) do if c.id == g.local_id do return fmt.tprintf("%s / %s", filepath.stem(path), c.name)
	}
	return "(missing clip)"
}

// --- Document access and undo --------------------------------------------------------

// The selected clip's asset document — the edit target. Refetched every frame:
// undo/redo swaps the document payload, so pointers never survive a frame.
// A clip inside a model is baked from the model and has no document: it comes
// back as the cached clip with a nil doc, which the view shows read-only.
@(private)
_pv_doc :: proc() -> (doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	if _pv.clip == {} do return nil, nil
	if _pv.clip.local_id != 0 {
		c, _ := anim.animation_clip_load(_pv.clip)
		return nil, c
	}
	path, ok := engine.asset_db_get_path(uuid.Identifier(_pv.clip.guid))
	if !ok do return nil, nil
	d := inspector.asset_doc_get(path)
	if d == nil || d.data.id != typeid_of(anim.AnimationClip) do return nil, nil
	return d, cast(^anim.AnimationClip)d.data.data
}

// The animation view edits a document across frames (dragging a keyframe), so
// its edit is a session like any other — opened when the gesture starts, closed
// when it ends. See docs/core/Undo.md.
@(private = "file")
_pv_session: undo.Edit_Session

// One whole-document undo step: the session captures the document before the
// mutation and records the result after. Drags open on press and close on
// release, mutating in between.
@(private)
_pv_edit_begin :: proc(doc: ^inspector.Asset_Doc) {
	// Idempotent: the drag calls this on activation, and a second call while the
	// same gesture is open would otherwise capture the already-edited value.
	if undo.edit_session_active(&_pv_session) do return
	_pv_session = undo.edit_session_begin(
		{undo.edit_target_asset(doc.guid, doc.data.id)}, "Animation Edit")
}

@(private)
_pv_edit_commit :: proc(doc: ^inspector.Asset_Doc) {
	if !_pv_edit_held do undo.edit_session_end(&_pv_session)
	_pv_mark_edited(doc)
}

// Set while one gesture runs several keyframe operations that each open and
// commit (recording a new row is a channel plus a key): _pv_edit_commit then
// leaves the session open, and the caller commits once at the end.
@(private)
_pv_edit_held: bool

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
			ch := &clip.channels[_av.sel_ch]
			if ch.path == .Rotation do _pv_normalize_rot_key(ch, _av.sel_key)
		}
		_pv_edit_commit(doc)
	}
}

@(private = "file")
_pv_normalize_rot_key :: proc(ch: ^anim.Animation_Channel, k: int) {
	vals := anim.animation_channel_floats(ch)
	v := vals[k]
	if l := linalg.length(v); l > 0.0001 do vals[k] = (1.0 / l) * v
}

@(private = "file")
_pv_sel_valid :: proc(clip: ^anim.AnimationClip) -> bool {
	if _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels) do return false
	return _av.sel_key >= 0 && _av.sel_key < len(clip.channels[_av.sel_ch].times)
}

// Value lanes a channel edits: transform channels by path, property channels
// by the LIVE field kind (clip_property.odin). An unresolved property channel
// edits one lane, painted yellow in the row list.
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
// property channels resolve their component guid and field path. The target
// is the Object row's label above, so the label leaves it out.
@(private = "file")
_pv_ch_label :: proc(ch: ^anim.Animation_Channel) -> (label: cstring, resolved: bool) {
	if !anim.animation_channel_is_property(ch) {
		return fmt.ctprintf("%v", ch.path), true
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
	return fmt.ctprintf("%s.%s", comp_name, ch.field), mok
}

// --- Keyframe operations --------------------------------------------------------------

// Insert a key at `t` sampling the curve's current value there, so adding a
// key never changes the curve's shape. With `value` given (recording) the key
// holds that value instead, and a key already at `t` takes it. A string value
// is cloned into the row.
@(private)
_pv_add_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx: int, t: f32, value: Maybe(anim.Channel_Value) = nil) {
	if doc == nil do return // read-only clip
	if ch_idx < 0 || ch_idx >= len(clip.channels) do return
	ch := &clip.channels[ch_idx]
	t := clamp(t, 0, clip.length)
	given, has_value := value.?
	for kt, i in ch.times {
		if abs(kt - t) >= 0.0005 do continue
		if !has_value do return
		_pv_edit_begin(doc)
		anim.animation_channel_set_value(ch, i, given)
		_pv_sel_set(ch_idx, i)
		_pv_edit_commit(doc)
		return
	}
	v := has_value ? given : anim._animation_channel_sample_value(ch, t)
	idx := len(ch.times)
	for kt, i in ch.times {
		if kt > t {
			idx = i
			break
		}
	}
	_pv_edit_begin(doc)
	anim.animation_channel_insert_key(ch, idx, t, v)
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
	if doc == nil || !_pv_sel_valid(clip) do return
	_pv_sel_prune(clip)
	if len(_av.sel) == 0 do return

	// Highest key index first, so each removal cannot shift the next one.
	refs := make([dynamic]_Key_Ref, 0, len(_av.sel), context.temp_allocator)
	append(&refs, .._av.sel[:])
	slice.sort_by(refs[:], proc(a, b: _Key_Ref) -> bool {
		return a.ch != b.ch ? a.ch > b.ch : a.key > b.key
	})

	_pv_edit_begin(doc)
	for r in refs {
		anim.animation_channel_remove_key(&clip.channels[r.ch], r.key)
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
_pv_channel_remove :: proc(clip: ^anim.AnimationClip, i: int) {
	ch := &clip.channels[i]
	delete(ch.target)
	delete(ch.component)
	delete(ch.field)
	delete(ch.times)
	anim.animation_channel_values_delete(&ch.values)
	delete(ch.modes)
	delete(ch.tangents)
	ordered_remove(&clip.channels, i)
}

// --- Key interpolation ------------------------------------------------------------------
//
// The key context menu and the footer set the selected keys' modes and apply
// tangent presets (curve_tools.odin). Each action is one undo step over every
// selected key. Keys of int, reference and string rows always hold, so the
// actions skip them.

// The modes every selected float key's row allows, and whether the selection
// holds a float key at all.
@(private = "file")
_pv_sel_modes :: proc(clip: ^anim.AnimationClip) -> (allowed: Key_Modes, floats: bool) {
	allowed = {.Linear, .Smooth, .Step, .Free}
	for r in _av.sel {
		if r.ch < 0 || r.ch >= len(clip.channels) do continue
		ch := &clip.channels[r.ch]
		if r.key < 0 || r.key >= len(ch.times) || !anim.animation_channel_is_float(ch) do continue
		floats = true
		allowed &= channel_modes_allowed(ch)
	}
	if !floats do allowed = {}
	return
}

// Whether every selected float key has `mode`.
@(private = "file")
_pv_sel_mode_all :: proc(clip: ^anim.AnimationClip, mode: anim.Key_Mode) -> bool {
	found := false
	for r in _av.sel {
		if r.ch < 0 || r.ch >= len(clip.channels) do continue
		ch := &clip.channels[r.ch]
		if r.key < 0 || r.key >= len(ch.times) || !anim.animation_channel_is_float(ch) do continue
		found = true
		if anim._animation_key_mode(ch, r.key) != mode do return false
	}
	return found
}

// Sets `mode` on every selected float key, one undo step. A key turning Free
// keeps the tangents it had. Nothing happens when a selected row does not
// allow the mode.
@(private)
_pv_keys_set_mode :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, mode: anim.Key_Mode) {
	if doc == nil do return
	_pv_sel_prune(clip)
	allowed, floats := _pv_sel_modes(clip)
	if !floats || mode not_in allowed do return
	_pv_edit_begin(doc)
	{
		// `modes` and `tangents` may be created here, and they live in the
		// document.
		context.allocator = inspector.doc_alloc()
		for r in _av.sel {
			ch := &clip.channels[r.ch]
			if anim.animation_channel_is_float(ch) do channel_set_key_mode(ch, r.key, mode)
		}
	}
	_pv_edit_commit(doc)
}

// Applies `preset` to every selected float key, one undo step: each becomes a
// Free key with the preset's tangents. Nothing happens when a selected row
// does not allow Free keys.
@(private)
_pv_keys_apply_preset :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, preset: Key_Preset) {
	if doc == nil do return
	_pv_sel_prune(clip)
	allowed, floats := _pv_sel_modes(clip)
	if !floats || .Free not_in allowed do return
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		for r in _av.sel {
			ch := &clip.channels[r.ch]
			if anim.animation_channel_is_float(ch) do channel_apply_preset(ch, r.key, preset)
		}
	}
	_pv_edit_commit(doc)
}

@(private = "file")
_pv_preset_label :: proc(p: Key_Preset) -> cstring {
	switch p {
	case .Flat:     return "Flat"
	case .Ease_In:  return "Ease In"
	case .Ease_Out: return "Ease Out"
	case .Auto:     return "Auto"
	}
	unreachable()
}

// The Mode group and the presets of the key context menu. A selection of
// discrete keys shows Step, disabled: those keys always hold.
@(private = "file")
_pv_draw_mode_items :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	allowed, floats := _pv_sel_modes(clip)
	im.SeparatorText("Mode")
	if !floats {
		im.MenuItem("Step", nil, true, false)
		return
	}
	for mode in anim.Key_Mode {
		if mode not_in allowed do continue
		if im.MenuItem(fmt.ctprintf("%v", mode), nil, _pv_sel_mode_all(clip, mode), doc != nil) {
			_pv_keys_set_mode(doc, clip, mode)
		}
	}
	if .Free not_in allowed do return
	im.SeparatorText("Tangents")
	for p in Key_Preset {
		if im.MenuItem(_pv_preset_label(p), nil, false, doc != nil) do _pv_keys_apply_preset(doc, clip, p)
	}
}

// The footer's mode combo: the primary key's mode, and the modes the
// selection allows to pick from. A pick applies to every selected key, as
// the context menu does. A discrete key shows Step, disabled.
@(private = "file")
_pv_draw_mode_combo :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch: ^anim.Animation_Channel, k: int) {
	im.SetNextItemWidth(80)
	if channel_modes_allowed(ch) == {} {
		im.BeginDisabled()
		if im.BeginCombo("##anim_key_mode", "Step") do im.EndCombo()
		im.EndDisabled()
		return
	}
	cur := anim._animation_key_mode(ch, k)
	if im.BeginCombo("##anim_key_mode", fmt.ctprintf("%v", cur)) {
		allowed, _ := _pv_sel_modes(clip)
		for mode in anim.Key_Mode {
			if mode not_in allowed do continue
			if im.Selectable(fmt.ctprintf("%v", mode), mode == cur) do _pv_keys_set_mode(doc, clip, mode)
		}
		im.EndCombo()
	}
}

// Sets key `k` of row `ch_idx` to `v`, one undo step. A string is cloned into
// the row.
@(private = "file")
_pv_set_key_value :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch_idx, k: int, v: anim.Channel_Value) {
	if doc == nil do return
	_pv_edit_begin(doc)
	{
		context.allocator = inspector.doc_alloc()
		anim.animation_channel_set_value(&clip.channels[ch_idx], k, v)
	}
	_pv_edit_commit(doc)
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
// plumbing (base) and the reference types that are not animatable (a PPtr is
// a leaf).
@(private = "file")
_pv_prop_leaves :: proc(tid: typeid, prefix: string, out: ^[dynamic]string, depth: int) {
	if depth > 4 do return
	names := reflect.struct_field_names(tid)
	types := reflect.struct_field_types(tid)
	for i in 0 ..< len(names) {
		name := names[i]
		if name == "base" do continue
		ftid := types[i].id
		if ftid == typeid_of(engine.Ref) || ftid == typeid_of(engine.Ref_Local) || ftid == typeid_of(engine.Owned) {
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

@(private)
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
	}, anim.Channel_Value(v))
}

@(private)
_pv_add_channel_property :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, target: string, guid_str: string, field: string, tH: engine.Transform_Handle) {
	for &c in clip.channels {
		if c.target == target && c.component == guid_str && c.field == field do return
	}
	// First key holds the field's CURRENT value, so adding a property never
	// visibly changes the object. The row's kind follows the field's: floats,
	// ints, references or strings (a string is cloned into the row).
	v: anim.Channel_Value = [4]f32{}
	if ptr, kind, leaf, ok := anim._prop_locate(tH, guid_str, field); ok {
		v = anim._prop_read_value(ptr, kind, leaf)
	}
	_pv_append_channel(doc, clip, anim.Animation_Channel{
		target    = strings.clone(target),
		component = strings.clone(guid_str),
		field     = strings.clone(field),
	}, v)
}

@(private = "file")
_pv_append_channel :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, ch: anim.Animation_Channel, v: anim.Channel_Value) {
	if doc == nil do return // read-only clip
	ch := ch
	_pv_edit_begin(doc)
	ch.times = make([dynamic]f32)
	ch.values = anim.animation_channel_values_make(v)
	anim.animation_channel_insert_key(&ch, 0, 0, v)
	append(&clip.channels, ch)
	_pv_sel_set(len(clip.channels) - 1, 0)
	_pv_collapse_clear(ch.target) // the new row shows, selected
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
	for r in _av.sel {
		if r.ch == ch_idx && r.key >= 0 && r.key < count do mask[r.key] = true
	}
	return mask
}

// --- Window ---------------------------------------------------------------------------

// The target and the transport: retargeting follows the selection and the
// playhead advances.
@(private = "file")
_animation_frame :: proc() {
	// A row value gesture whose field stopped being drawn mid-drag (the window
	// closed) is over: nothing is active any more.
	if _pv_row_gesture && !im.IsAnyItemActive() do _pv_row_gesture_end()

	owner, a := _pv_target()
	if a == nil {
		_pv_preview_off()
		return
	}
	// Retarget follows selection: the old target's graph and binding
	// belong to the old owner.
	if owner != _pv.owner {
		_pv_teardown()
		_pv_deselect_all()
		_pv.owner = owner
	}

	clips := _pv_clips(a)
	if len(clips) == 0 {
		_pv_preview_off()
		return
	}
	in_list := false
	for c in clips {
		if c == _pv.clip do in_list = true
	}
	if !in_list {
		_pv_teardown()
		_pv_deselect_all()
		_pv.clip = clips[0]
		_pv.time = 0
	}

	_, clip := _pv_doc()
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001
	_pv_advance(clip, length)
}

@(editor_window={id="Animation", title="Animation", icon="ANIMATION", closed=animation_view_closed})
animation_view_draw :: proc(w: ^wnd.Window) {
	_av = _anim_view(w)
	defer {
		last := wnd.last(ANIMATION_VIEW)
		_av = _anim_view(last) if last != nil else &_av_none
	}

	_, a := _pv_target()
	if a == nil {
		im.TextDisabled("Select an object with an Animation component.")
		return
	}
	clips := _pv_clips(a)
	if len(clips) == 0 {
		im.TextDisabled("The Animation component has no clips.")
		return
	}

	doc, clip := _pv_doc()
	length := clip != nil ? max(clip.length, 0.0001) : 0.0001

	// Read-only is a clip inside a model. A missing or unreadable .anim has no
	// document either, and the edit guards stop on that, but it is not marked
	// Read-Only: the sheet says the clip is missing.
	_pv_draw_toolbar(clip, length, read_only = _pv.clip.local_id != 0)
	_record_draw_note()

	if clip == nil {
		// The picker still draws, so a broken clip is not a dead end.
		_pv_draw_sheet_header(doc, nil, clips, _av.left_w)
		im.TextDisabled("The clip is missing or unreadable.")
		return
	}
	// Undo may have shrunk the clip since the selection was made.
	if _av.sel_ch >= len(clip.channels) do _pv_deselect()
	if _av.sel_ch >= 0 && _av.sel_key >= len(clip.channels[_av.sel_ch].times) do _av.sel_key = -1
	_pv_sel_prune(clip)

	// The sheet, then the view tabs under it: the tabs belong to the sheet,
	// not to the transport, so they sit at its bottom edge.
	footer := _pv_sel_valid(clip)
	tabs_h := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y
	body_h := -(tabs_h + (footer ? im.GetFrameHeight() + 8 : 0))
	// NoScrollWithMouse: over the time canvas the wheel ZOOMS, and imgui
	// scrolling this child at the same time made the sheet drift under the
	// cursor mid-zoom. The property-name column has no such claim, so the wheel
	// there scrolls by hand below — the sequencer splits its two halves the
	// same way.
	im.BeginChild("##anim_body", im.Vec2{0, body_h}, {.Borders}, {.NoScrollWithMouse})
	_pv_draw_sheet(doc, clip, clips)
	if !_av.over_canvas && im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
		if wheel := im.GetIO().MouseWheel; wheel != 0 {
			im.SetScrollY(im.GetScrollY() - wheel * im.GetTextLineHeightWithSpacing() * 3)
		}
	}
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
		if d2, c2 := _pv_doc(); d2 != nil && c2 != nil {
			anim.animation_clip_preview(engine.PPtr{guid = d2.guid}, c2^)
		}
	}
}

@(private = "file")
_pv_draw_toolbar :: proc(clip: ^anim.AnimationClip, length: f32, read_only: bool) {
	fps := anim.animation_clip_frame_rate(clip)

	// Preview toggle. The pop must match the state at push time — the click
	// flips _pv.active in between.
	tinted := _pv.active
	if tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Preview") {
		if _pv.active {
			_pv_preview_off()
		} else {
			_pv.active = true
		}
	}
	if tinted do im.PopStyleColor()
	widgets.tooltip("Pose the object from this clip while the window is open")

	// Record: while armed, an edit of an animatable field keys the clip at the
	// playhead (record.odin). The record light is red whether armed or not,
	// brighter while armed. The Text push is what colors the glyph the shared
	// button draws. A read-only clip has nothing to record into.
	im.SameLine()
	if read_only do _pv.recording = false
	rec := _pv.recording
	im.PushStyleColorImVec4(.Text, rec ? im.Vec4{0.95, 0.25, 0.25, 1} : im.Vec4{0.75, 0.35, 0.35, 1})
	im.BeginDisabled(read_only)
	armed := widgets.icon_button(icons.ICON_MD_RECORD, "##rec",
		"Record: editing any animatable field keys it at the playhead, the object keeps its own value", active = rec)
	im.EndDisabled()
	im.PopStyleColor()
	if armed {
		_pv.recording = !_pv.recording
		if _pv.recording do _pv.active = true // recording poses the object, as previewing does
	}
	if !_pv.recording do _record_note_clear()

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
		if _pv.playing {
			_pv.active = true
			// Pressing play with the playhead already at the end replays from
			// the start. Without this the first press only advances past the
			// end, which _pv_advance answers by rewinding AND stopping — so it
			// took two presses to play, the first one looking like a rewind.
			if _pv.time >= length do _pv.time = 0
		}
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

	// Playback: once, loop, or as the clip's wrap setting. A click steps to the
	// next state, and the tooltip names the one a click gives.
	im.SameLine()
	glyph, tip: cstring
	switch _anim_playback() {
	case .Once:
		glyph, tip = icons.ICON_MD_REPEAT_ONE, "Play once, then stop\nClick: loop"
	case .Loop:
		glyph, tip = icons.ICON_MD_REPEAT, "Loop\nClick: match the clip's wrap setting"
	case .Clip:
		glyph = icons.ICON_MD_EVENT_REPEAT
		tip = fmt.ctprintf("Match the clip's wrap setting (%v)\nClick: play once", _pv_clip_wrap())
	}
	if widgets.icon_button(glyph, "##playback", tip) {
		anim_view_prefs.playback = Anim_Playback((int(anim_view_prefs.playback) + 1) % len(Anim_Playback))
	}

	// The playhead as a frame number, with the clip's frame count beside it.
	im.SameLine()
	im.SetNextItemWidth(58)
	frame := i32(math.round(_pv.time * fps))
	if im.InputInt("##pv_frame", &frame, 0, 0, {.EnterReturnsTrue}) {
		_pv.time = clamp(f32(frame) / fps, 0, length)
		_pv.active = true
	}
	widgets.tooltip("Playhead frame")
	im.SameLine()
	im.TextDisabled(fmt.ctprintf("/ %d", i32(math.round(length * fps))))

	if read_only {
		im.SameLine(0, 16)
		im.TextDisabled(icons.ICON_MD_LOCK + " Read-Only")
		widgets.tooltip("A clip inside a model is read-only. Assets/Extract Assets makes an editable .anim")
	}

	// No Save button: the tab menu saves and discards the clip, File/Save
	// saves it with every other file (session/documents.odin).
}

// The clip the view edits: the tab menu saves and discards it, and the tab
// title carries its star.
@(view_document={view="Animation"})
animation_view_document :: proc(view: session.View) -> engine.Asset_GUID {
	doc, _ := _pv_doc()
	return doc.guid if doc != nil else {}
}

// Header of the property column: the clip picker, stretched to the column
// width, and the key button beside it. Both act on the track list below them
// rather than on the transport, so they sit at its head.
@(private = "file")
_pv_draw_sheet_header :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.PPtr, left_w: f32) {
	key_w := im.GetFrameHeight()
	combo_w := max(left_w - key_w - im.GetStyle().ItemSpacing.x, 1)

	im.SetNextItemWidth(combo_w)
	cur := strings.clone_to_cstring(_pv_clip_name(_pv.clip), context.temp_allocator)
	if im.BeginCombo("##pv_clip", cur) {
		for c in clips {
			// A clip inside a model has no document to edit. The list marks it,
			// the toolbar marks the open one.
			name := fmt.ctprintf("%s (Read-Only)" if c.local_id != 0 else "%s", _pv_clip_name(c))
			if im.Selectable(name, c == _pv.clip) && c != _pv.clip {
				_pv_teardown()
				_pv_deselect()
				_pv.entry = 0 // the window takes the preview back from the States tree
				_pv.clip = c
				_pv.time = 0
			}
		}
		im.EndCombo()
	}
	widgets.tooltip("Clip to edit")

	im.SameLine()
	im.BeginDisabled(doc == nil || clip == nil || _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels))
	if widgets.icon_button(icons.ICON_MD_KEYFRAME, "##addkey", "Add a keyframe on the selected property") {
		_pv_add_key(doc, clip, _av.sel_ch, _pv.time)
	}
	im.EndDisabled()
}

// Dopesheet / Curves, as tabs along the bottom of the sheet.
@(private = "file")
_pv_draw_mode_tabs :: proc() {
	if !im.BeginTabBar("##anim_modes", {}) do return
	defer im.EndTabBar()
	// imgui owns which tab is open and _av.mode follows it. Forcing the open
	// tab from _av.mode every frame would re-select the current one before a
	// click on the other could take effect.
	for mode in _Anim_Mode {
		if im.BeginTabItem(fmt.ctprintf("%v", mode), nil, {}) {
			_av.mode = mode
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

// This view's per-developer preferences, persisted to UserSettings/animation.json.
// Not project settings: where someone's playhead stops is about them, not the
// project, and the game binary has no business reading it.
Anim_View_Prefs :: struct {
	// Where the playhead lands when a Once clip finishes: the last frame, or
	// back at the first. Off by default, which is how it has always behaved.
	ends_on_last_frame: bool,
	// The toolbar's playback toggle.
	playback: Anim_Playback,
	// The ruler over the time canvas (the view menu's three Ruler items).
	ruler: Anim_Ruler,
}

// How the transport plays a clip. Saved as an integer: Clip stays zero, so a
// settings file without the field follows the clip.
Anim_Playback :: enum {
	Clip, // as the clip's wrap setting says, which is what the component does
	Once, // plays through and stops, even a Loop clip
	Loop, // cycles, even a Once clip
}

// What the ruler over the time canvas shows. Saved as an integer: the
// default stays zero.
Anim_Ruler :: enum {
	Frames_And_Time, // two rulers, each half the band: time above, frames below
	Frames,
	Time,
}

@(private = "file")
_anim_ruler :: proc() -> Anim_Ruler {
	r := anim_view_prefs.ruler
	if r < min(Anim_Ruler) || r > max(Anim_Ruler) do anim_view_prefs.ruler = .Frames_And_Time
	return anim_view_prefs.ruler
}

// The saved playback state. A settings file can hold an integer out of the
// enum's range, which reads as Clip and is stored back as Clip.
@(private = "file")
_anim_playback :: proc() -> Anim_Playback {
	p := anim_view_prefs.playback
	if p < min(Anim_Playback) || p > max(Anim_Playback) do anim_view_prefs.playback = .Clip
	return anim_view_prefs.playback
}

@(user_settings={name="Animation"})
anim_view_prefs: Anim_View_Prefs

// The menu item is an ACTION with a checked predicate rather than a toggle,
// because a toggle writes through a ^bool and would need its own variable —
// two places holding the same preference, one of them persisted.
@(view_menu={view="Animation", label="Play Ends on Last Frame", checked=anim_ends_on_last_frame})
anim_toggle_ends_on_last_frame :: proc(view: session.View) {
	anim_view_prefs.ends_on_last_frame = !anim_view_prefs.ends_on_last_frame
}

anim_ends_on_last_frame :: proc(view: session.View) -> bool {
	return anim_view_prefs.ends_on_last_frame
}

// The ruler, a three-way choice in the Ruler submenu: one checked item per state.
@(view_menu={view="Animation", label="Ruler/Frames and Time", checked=anim_ruler_is_both})
anim_ruler_pick_both :: proc(view: session.View) { anim_view_prefs.ruler = .Frames_And_Time }
@(view_menu={view="Animation", label="Ruler/Frames", checked=anim_ruler_is_frames})
anim_ruler_pick_frames :: proc(view: session.View) { anim_view_prefs.ruler = .Frames }
@(view_menu={view="Animation", label="Ruler/Time", checked=anim_ruler_is_time})
anim_ruler_pick_time :: proc(view: session.View) { anim_view_prefs.ruler = .Time }
anim_ruler_is_both :: proc(view: session.View) -> bool { return _anim_ruler() == .Frames_And_Time }
anim_ruler_is_frames :: proc(view: session.View) -> bool { return _anim_ruler() == .Frames }
anim_ruler_is_time :: proc(view: session.View) -> bool { return _anim_ruler() == .Time }

// The IMPORTED clip's wrap, not the edited document's: wrap is authored in the
// .meta and baked into the artifact, so the document has none.
@(private = "file")
_pv_clip_wrap :: proc() -> anim.Animation_Wrap {
	if imported, ok := anim.animation_clip_load(_pv.clip); ok do return imported.wrap
	return .Once
}

// Advance the playhead while the transport runs. By default it wraps the way
// the clip itself does, so playback matches what the component will do — a
// Once clip plays through and stops, a Loop clip cycles. The playback toggle
// can force either.
@(private = "file")
_pv_advance :: proc(clip: ^anim.AnimationClip, length: f32) {
	if !_pv.playing do return
	gfx.keep_awake()
	_pv.time, _pv.playing = anim_playback_step(_pv.time, gfx.delta_time(), length,
		_pv_clip_wrap(), _anim_playback(), anim_view_prefs.ends_on_last_frame)
}

// One transport step of a running playhead: `time` advanced by `dt`, and
// past `length` wrapped by `playback`, which keeps `clip_wrap` (Clip) or
// forces Once or Loop. A Once playback stops there (playing false). No gfx
// or imgui calls.
anim_playback_step :: proc(time, dt, length: f32, clip_wrap: anim.Animation_Wrap, playback: Anim_Playback, ends_on_last_frame: bool) -> (new_time: f32, playing: bool) {
	new_time = time + dt
	if new_time < length do return new_time, true
	wrap := clip_wrap
	switch playback {
	case .Clip:
	case .Once: wrap = .Once
	case .Loop: wrap = .Loop
	}
	switch wrap {
	case .Loop:
		return new_time - length * math.floor(new_time / length), true
	case .Once:
		// Where a Once clip comes to rest. Ending ON the last frame is what you
		// want when the pose it lands in is the thing being authored — a death,
		// a landing, anything whose final frame is the point. Rewinding is what
		// you want when you are watching the motion over and over.
		return ends_on_last_frame ? length : 0, false
	}
	return new_time, true
}

// The sheet: property rows on the left, the time canvas (ruler + dopesheet
// keys or curves) on the right, one interaction surface each.
@(private = "file")
_pv_draw_sheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, clips: []engine.PPtr) {
	dl := im.GetWindowDrawList()
	origin := im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	if avail.x < _ANIM_MIN_LEFT_W + widgets.SPLITTER_SIZE + _ANIM_MIN_CANVAS_W {
		im.TextDisabled("Window too narrow.")
		return
	}

	length := max(clip.length, 0.0001)
	// Property column | splitter gap | time canvas.
	left_w := clamp(_av.left_w, _ANIM_MIN_LEFT_W, avail.x - widgets.SPLITTER_SIZE - _ANIM_MIN_CANVAS_W)
	// The ruler band spans the whole sheet, but only the canvas half of it
	// holds the ruler — the property column's half takes the header controls.
	// It is at least a frame tall so they fit without a row of their own.
	ruler_h := max(_ANIM_RULER_H, im.GetFrameHeight())

	// Header in the property column's half of the band. Drawn before the two
	// interaction surfaces below, which the mode handlers read as the last
	// item, and clear of both in x and y.
	im.SetCursorScreenPos(origin)
	_pv_draw_sheet_header(doc, clip, clips, left_w)

	left_x1 := origin.x + left_w
	x0 := left_x1 + widgets.SPLITTER_SIZE
	x1 := origin.x + avail.x
	// Time axis: pps (pixels per second) is the fit scale times the zoom, so
	// zoom 1 shows the whole clip and no pan is possible.
	if _av.zoom < 1 do _av.zoom = 1
	span_px := max(x1 - x0 - 2 * _ANIM_PAD_X, 1)
	pps_fit := span_px / length
	pps := pps_fit * _av.zoom
	visible := span_px / pps // seconds across the canvas
	_av.pan = clamp(_av.pan, 0, max(length - visible, 0))
	tx0 := x0 + _ANIM_PAD_X - _av.pan * pps // x of t=0

	// The visible rows: an Object row per animated transform, its property
	// rows under it unless collapsed (sheet_rows.odin).
	rows := sheet_rows(clip, _av.collapsed, context.temp_allocator)
	nrows := len(rows)
	rows_y := origin.y + ruler_h
	body_h: f32
	if _av.mode == .Dopesheet {
		// Fills the pane rather than stopping at the last track: the empty
		// area below the tracks is where a box selection often starts.
		body_h = max(f32(nrows) * _ANIM_ROW_H, max(avail.y - ruler_h, _ANIM_ROW_H))
	} else {
		body_h = max(f32(nrows)*_ANIM_ROW_H, max(avail.y - ruler_h, 140))
	}

	// --- Zoom and pan on the time axis. Zoom keeps the time under the cursor
	// in place, which is what makes wheel zoom feel anchored.
	{
		mp := im.GetMousePos()
		// Resolved every frame so a gesture times out even while the pointer
		// is elsewhere; only acted on while the canvas is under it.
		wheel_v, wheel_h := widgets.wheel_dominant(&_av.wheel)
		over_canvas := im.IsWindowHovered(im.HoveredFlags_ChildWindows) && mp.x >= x0 && mp.x <= x1
		_av.over_canvas = over_canvas
		if over_canvas {
			if wheel := wheel_v; wheel != 0 {
				t_at := (mp.x - tx0) / pps
				_av.zoom = clamp(_av.zoom * math.pow(f32(1.15), wheel), 1, 200)
				new_pps := pps_fit * _av.zoom
				_av.pan = t_at + (x0 + _ANIM_PAD_X - mp.x) / new_pps
				pps = new_pps
				visible = span_px / pps
				_av.pan = clamp(_av.pan, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
			// Horizontal wheel (a trackpad's sideways swipe) pans, signed the
			// way imgui scrolls its own windows: positive moves the view
			// toward earlier time.
			if wheel_h != 0 {
				step := span_px * 0.15 / pps // a sixth of the view per notch
				_av.pan = clamp(_av.pan - wheel_h * step, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
			// Middle-drag pans too, for a mouse without a sideways wheel.
			if im.IsMouseDragging(.Middle, 1) {
				_av.pan = clamp(_av.pan - im.GetIO().MouseDelta.x / pps, 0, max(length - visible, 0))
				tx0 = x0 + _ANIM_PAD_X - _av.pan * pps
			}
		}
	}

	// Canvas drawing is clipped to its own column: zoomed in, keys and ticks
	// fall outside it and would otherwise paint over the property panel.
	canvas_clip_min := im.Vec2{x0, origin.y}
	canvas_clip_max := im.Vec2{x1, rows_y + body_h}

	// --- Ruler: dragging it scrubs (the only scrub surface).
	im.SetCursorScreenPos(im.Vec2{x0, origin.y})
	im.InvisibleButton("##anim_ruler", im.Vec2{max(x1 - x0, 1), ruler_h})
	if im.IsItemActive() {
		_pv.time = clamp(_pv_snap_time(clip, (im.GetMousePos().x - tx0) / pps), 0, clip.length)
		_pv.active = true
	}
	im.DrawList_AddRectFilled(dl, im.Vec2{x0, origin.y}, im.Vec2{x1, origin.y + ruler_h}, im.GetColorU32(.FrameBg, 0.6))
	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	fps := anim.animation_clip_frame_rate(clip)
	switch _anim_ruler() {
	case .Time:
		_pv_ruler_time(dl, origin.y, ruler_h, tx0, pps, length)
	case .Frames:
		_pv_ruler_frames(dl, origin.y, ruler_h, tx0, pps, length, fps)
	case .Frames_And_Time:
		// Each ruler takes half the band: time above, frames below, next to
		// the keys they count. A divider parts the two.
		half := ruler_h * 0.5
		_pv_ruler_time(dl, origin.y, half, tx0, pps, length)
		im.DrawList_AddLine(dl, im.Vec2{x0, origin.y + half}, im.Vec2{x1, origin.y + half}, im.GetColorU32(.Border), 1)
		_pv_ruler_frames(dl, origin.y + half, half, tx0, pps, length, fps)
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
	// The sheet row under the pointer, -1 off the rows (below the last one).
	row_at := hovered ? int((mp.y - rows_y) / _ANIM_ROW_H) : -1
	if row_at >= nrows do row_at = -1

	// A press on an Object row's arrow (or the indent left of it) collapses or
	// expands it, in both modes. This frame keeps the rows it built, the next
	// frame shows the change. A double-click on its name opens the path field.
	root_name := _pv_root_name()
	if row_at >= 0 && rows[row_at].kind == .Object && mp.x < left_x1 {
		r := rows[row_at]
		name_x := _pv_obj_name_x(origin.x, _pv_row_indent(r))
		if im.IsItemActivated() && mp.x < name_x do _pv_collapse_toggle(r.target)
		if mp.x >= name_x && doc != nil && im.IsMouseDoubleClicked(.Left) do _pv_path_edit_begin(r.target)
		if !(_av.path_edit && _av.path_target == r.target) {
			full := r.target == "" ? root_name : r.target
			if _, ok := anim._animation_resolve_target(_pv.owner, r.target); ok {
				widgets.tooltip_unchecked(fmt.ctprintf("%s", full))
			} else {
				widgets.tooltip_unchecked(fmt.ctprintf("%s\nNot found under %s", full, root_name))
			}
		}
	}

	// Left panel rows (both modes: this is where curves pick their channel).
	// An Object row shows its arrow and the transform's name. A property row's
	// value fields sit at the column's right edge and the name is clipped
	// short of them.
	im.DrawList_PushClipRect(dl, im.Vec2{origin.x, rows_y}, im.Vec2{left_x1, rows_y + body_h}, true)
	for r, i in rows {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		if r.kind == .Object {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.6))
			name_x := _pv_obj_name_x(origin.x, _pv_row_indent(r))
			_pv_draw_collapse_arrow(dl, im.Vec2{name_x - 4 - _ANIM_ARROW_W * 0.5, ry + _ANIM_ROW_H * 0.5}, !_av.collapsed[r.target])
			if _av.path_edit && _av.path_target == r.target do continue // the path field covers the name
			_pv_draw_obj_label(dl, r.target, root_name, name_x, ry, left_x1 - 4)
			continue
		}
		ch := &clip.channels[r.ch]
		if r.ch == _av.sel_ch {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.Header, 0.7))
		} else if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{origin.x, ry}, im.Vec2{left_x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		label, resolved := _pv_ch_label(ch)
		col := resolved ? im.GetColorU32(.Text) : im.GetColorU32ImVec4(_ANIM_WARN_COL)
		name_x1 := left_x1 - _pv_row_values_w(ch) - 8
		im.DrawList_PushClipRect(dl, im.Vec2{origin.x, ry}, im.Vec2{max(name_x1, origin.x), ry + _ANIM_ROW_H}, true)
		im.DrawList_AddText(dl, im.Vec2{origin.x + 6 + f32(_pv_row_indent(r)) * _ANIM_INDENT, ry + 3}, col, label)
		im.DrawList_PopClipRect(dl)
	}
	im.DrawList_PopClipRect(dl)

	// Right-click a property row: channel operations. An Object row has none.
	if hovered && mp.x < x0 && row_at >= 0 && rows[row_at].kind == .Channel &&
	   im.IsMouseClicked(.Right) {
		_av.sel_ch = rows[row_at].ch
		_av.sel_key = -1
		im.OpenPopup("##anim_ch_ctx")
	}
	// Right-click an Object row: its path.
	if hovered && mp.x < x0 && row_at >= 0 && rows[row_at].kind == .Object &&
	   im.IsMouseClicked(.Right) {
		_pv_view_str_set(&_av.ctx_target, rows[row_at].target)
		im.OpenPopup("##anim_obj_ctx")
	}
	if im.BeginPopup("##anim_obj_ctx") {
		if im.MenuItem("Edit Path", nil, false, doc != nil) do _pv_path_edit_begin(_av.ctx_target)
		im.EndPopup()
	}
	if im.BeginPopup("##anim_ch_ctx") {
		if im.MenuItem("Remove Property", nil, false, doc != nil) && _av.sel_ch >= 0 && _av.sel_ch < len(clip.channels) {
			_pv_edit_begin(doc)
			_pv_channel_remove(clip, _av.sel_ch)
			_pv_deselect()
			_pv_edit_commit(doc)
		}
		im.EndPopup()
	}

	im.DrawList_PushClipRect(dl, canvas_clip_min, canvas_clip_max, true)
	if _av.mode == .Dopesheet {
		// A tangent drag belongs to the curve view: leaving it ends the drag.
		if _av.drag_tan do _pv_tan_drag_end(doc, true)
		_pv_sheet_dopesheet(doc, clip, dl, rows, rows_y, body_h, x0, x1, tx0, pps, hovered, mp, row_at)
	} else {
		_pv_sheet_curves(doc, clip, dl, rows, rows_y, body_h, x0, x1, tx0, pps, mp, row_at)
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
	if _av.drag_key {
		if !_pv_sel_valid(clip) || len(_av.sel) != len(_av.drag_t0) {
			// A key vanished mid-drag, so there is no edit to record.
			_av.drag_key = false
			undo.edit_session_abort(&_pv_session)
		} else if im.IsMouseDown(.Left) {
			// A press is a click until the mouse has moved a few pixels: a
			// click selects and must not nudge the key's time or value.
			if !_av.drag_live {
				if linalg.length(mp - _av.drag_press) < _ANIM_DRAG_PX do return
				_av.drag_live = true
			}
			// One delta for the whole selection, snapped, then clamped by the
			// tightest neighbour bound among the dragged keys so none of them
			// can cross another and reorder the channel.
			want := _pv_snap_time(clip, (mp.x - tx0) / pps) - _av.drag_from
			lo_d, hi_d := -max(f32), max(f32)
			for r, i in _av.sel {
				ch := &clip.channels[r.ch]
				mask := _pv_sel_mask(r.ch, len(ch.times))
				lo, hi := anim.animation_key_bounds(ch.times[:], mask, r.key, clip.length)
				lo_d = max(lo_d, lo - _av.drag_t0[i])
				hi_d = min(hi_d, hi - _av.drag_t0[i])
			}
			d := clamp(want, lo_d, hi_d)
			for r, i in _av.sel {
				clip.channels[r.ch].times[r.key] = _av.drag_t0[i] + d
			}
			if _av.drag_comp >= 0 && anim.animation_channel_is_float(&clip.channels[_av.sel_ch]) {
				// Curves: y edits the grabbed component's value on the primary
				// key only — the others have their own values to keep.
				ch := &clip.channels[_av.sel_ch]
				anim.animation_channel_floats(ch)[_av.sel_key][_av.drag_comp] = _pv_curve_y_to_v(mp.y, rows_y, body_h)
			}
			_pv_mark_edited(doc)
		} else if !_av.drag_live {
			// Released without moving: a click, nothing to record.
			undo.edit_session_abort(&_pv_session)
			_av.drag_key = false
		} else {
			ch := &clip.channels[_av.sel_ch]
			if ch.path == .Rotation && _av.drag_comp >= 0 do _pv_normalize_rot_key(ch, _av.sel_key)
			_pv_edit_commit(doc)
			_av.drag_key = false
		}
	}

	// Key context menu (opened by the mode-specific right-click handling).
	if im.BeginPopup("##anim_key_ctx") {
		_pv_draw_mode_items(doc, clip)
		im.Separator()
		can_delete := doc != nil && _pv_sel_valid(clip)
		label: cstring = len(_av.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_av.sel)) : "Delete Key"
		if im.MenuItem(label, nil, false, can_delete) do _pv_delete_key(doc, clip)
		im.EndPopup()
	}

	_pv_draw_row_values(doc, clip, rows, rows_y, left_x1)
	_pv_draw_path_field(doc, rows, origin.x, rows_y, left_x1)

	// Add Property closes the track list, under the last row. Submitted after
	// the mode handlers for the same reason as the splitter below — they read
	// the sheet button as the last item. A press here lands in the property
	// column below every row, so it matches no sheet case either way.
	// Fixed width, centered in the column, as the inspector's Add Component is
	// — narrowed only when the column is too thin to hold it.
	add_w := min(f32(220), max(left_w - 8, 1))
	im.SetCursorScreenPos(im.Vec2{
		origin.x + (left_w - add_w) * 0.5,
		rows_y + f32(nrows) * _ANIM_ROW_H + 4,
	})
	im.BeginDisabled(doc == nil)
	if im.Button("Add Property", im.Vec2{add_w, 0}) do im.OpenPopup("##anim_add_prop")
	im.EndDisabled()
	if im.BeginPopup("##anim_add_prop") {
		_pv_add_prop_object(doc, clip, _pv.owner, "", 0)
		im.EndPopup()
	}

	// Splitter between the property column and the canvas. Submitted LAST:
	// the mode handlers above query the sheet button as the last item, and a
	// later item is what wins the pointer over the AllowOverlap sheet.
	canvas_w := x1 - x0
	im.SetCursorScreenPos(im.Vec2{left_x1, origin.y})
	if widgets.splitter("##anim_split", true, &left_w, &canvas_w, _ANIM_MIN_LEFT_W, _ANIM_MIN_CANVAS_W) {
		_av.left_w = left_w
	}
}

// The animated object's name, the root Object row's label.
@(private = "file")
_pv_root_name :: proc() -> string {
	w := engine.ctx_world()
	if t := engine.pool_get(&w.transforms, engine.Handle(_pv.owner)); t != nil && t.name != "" do return t.name
	return "(self)"
}

// How far a row indents: an Object row sits at the column's edge whatever its
// path depth (the dimmed parent path says where it is), its property rows one
// step in.
@(private = "file")
_pv_row_indent :: proc(r: Sheet_Row) -> int {
	return r.kind == .Channel ? 1 : 0
}

// Where an Object row's name starts: its indent, then the arrow.
@(private = "file")
_pv_obj_name_x :: proc(x0: f32, depth: int) -> f32 {
	return x0 + 6 + f32(depth) * _ANIM_INDENT + _ANIM_ARROW_W + 4
}

// An Object row's label from `x` up to `x_max`: the transform's name, after
// its parent path dimmed when both fit ("Armature / node_2"). Warning colour
// when the target does not resolve under the animated object.
@(private = "file")
_pv_draw_obj_label :: proc(dl: ^im.DrawList, target, root_name: string, x, y, x_max: f32) {
	parent, name, _ := sheet_target_split(target)
	if target == "" do name = root_name
	_, resolved := anim._animation_resolve_target(_pv.owner, target)
	col := resolved ? im.GetColorU32(.Text) : im.GetColorU32ImVec4(_ANIM_WARN_COL)
	name_c := fmt.ctprintf("%s", name)
	im.DrawList_PushClipRect(dl, im.Vec2{x, y}, im.Vec2{max(x_max, x), y + _ANIM_ROW_H}, true)
	defer im.DrawList_PopClipRect(dl)
	nx := x
	if parent != "" {
		prefix := fmt.ctprintf("%s / ", parent)
		pw := im.CalcTextSize(prefix, nil, false, -1).x
		if x + pw + im.CalcTextSize(name_c, nil, false, -1).x <= x_max {
			im.DrawList_AddText(dl, im.Vec2{x, y + 3}, im.GetColorU32(.TextDisabled), prefix)
			nx += pw
		}
	}
	im.DrawList_AddText(dl, im.Vec2{nx, y + 3}, col, name_c)
}

// An Object row's collapse arrow centered on `c`: pointing down when open,
// right when collapsed.
@(private = "file")
_pv_draw_collapse_arrow :: proc(dl: ^im.DrawList, c: im.Vec2, open: bool) {
	r := f32(4)
	col := im.GetColorU32(.Text)
	if open {
		im.DrawList_AddTriangleFilled(dl, c + {-r, -r * 0.6}, c + {r, -r * 0.6}, c + {0, r * 0.6}, col)
	} else {
		im.DrawList_AddTriangleFilled(dl, c + {-r * 0.6, -r}, c + {r * 0.6, 0}, c + {-r * 0.6, r}, col)
	}
}

// --- Object row path field ------------------------------------------------------------
//
// Retargeting: a renamed transform leaves its rows unresolved, so the Object
// row's path is editable. A double-click on its name or "Edit Path" in its
// menu opens a field holding the full target path. Enter applies through
// animation_view_retarget, Escape and a click elsewhere cancel.

@(private = "file")
_pv_path_edit_begin :: proc(target: string) {
	_pv_view_str_set(&_av.path_target, target)
	_av.path_edit = true
	// A field opened from the menu races the closing popup for focus, so it
	// asks again for a few frames before giving up.
	_av.path_wait = 10
	_av.path_buf = {}
	copy(_av.path_buf[:len(_av.path_buf) - 1], target)
}

@(private = "file")
_pv_draw_path_field :: proc(doc: ^inspector.Asset_Doc, rows: []Sheet_Row, x0, rows_y, left_x1: f32) {
	if !_av.path_edit do return
	row := -1
	for r, i in rows {
		if r.kind == .Object && r.target == _av.path_target {
			row = i
			break
		}
	}
	// The row went away (undo, a clip switch) or the clip is read-only.
	if row < 0 || doc == nil {
		_av.path_edit = false
		return
	}
	// Escape commits the typed path, as in every text field (editor/text_input.odin).
	// A click elsewhere cancels.
	field_h := _pv_row_field_h()
	x := _pv_obj_name_x(x0, rows[row].depth)
	im.PushStyleVarImVec2(.FramePadding, im.Vec2{3, _pv_row_pad_y()})
	if _av.path_wait > 0 do im.SetKeyboardFocusHere(0)
	im.SetCursorScreenPos(im.Vec2{x, rows_y + f32(row) * _ANIM_ROW_H + (_ANIM_ROW_H - field_h) * 0.5})
	im.SetNextItemWidth(max(left_x1 - 4 - x, 40))
	entered := im.InputText("##anim_path", cstring(raw_data(_av.path_buf[:])), uint(len(_av.path_buf)), {.EnterReturnsTrue, .AutoSelectAll})
	active := im.IsItemActive()
	im.PopStyleVar(1)

	if entered {
		_av.path_edit = false
		animation_view_retarget(_av.path_target, string(cstring(raw_data(_av.path_buf[:]))))
		return
	}
	if _av.path_wait > 0 {
		if active {
			_av.path_wait = 0
		} else {
			_av.path_wait -= 1
			if _av.path_wait == 0 do _av.path_edit = false
		}
	} else if !active {
		_av.path_edit = false // clicked elsewhere: cancel
	}
}

// Sets the target of every channel of `old_target` in the shown clip to
// `new_target` (spaces trimmed, otherwise as typed), as one undo step. The
// collapsed state follows the row. False with nothing to change: no
// document (a clip inside a model), no channel on `old_target`, or the same
// path. The Object row path field applies through this.
animation_view_retarget :: proc(old_target, new_target: string) -> bool {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return false
	// Copies: `old_target` may be a channel's own string, freed below.
	old := strings.clone(old_target, context.temp_allocator)
	new := strings.clone(strings.trim_space(new_target), context.temp_allocator)
	if new == old do return false
	found := false
	for &c in clip.channels do if c.target == old do found = true
	if !found do return false

	_pv_edit_begin(doc)
	// Channel strings live in the document.
	a := inspector.doc_alloc()
	for &c in clip.channels {
		if c.target != old do continue
		delete(c.target, a)
		c.target = strings.clone(new, a)
	}
	_pv_edit_commit(doc)

	if old in _av.collapsed {
		_pv_collapse_toggle(old)
		if new not_in _av.collapsed do _pv_collapse_toggle(new)
	}
	return true
}

// --- Row values -----------------------------------------------------------------------
//
// Each property row shows its value at the playhead after its name: one small
// field per lane (a vec3 three, a bool a checkbox, an int or enum an int
// field, a string a text field committed by Enter, a reference the asset
// picker the inspector uses). A Rotation row shows three euler angles in
// degrees, converted from the sampled
// quaternion as the inspector's Rotation row converts, and an edit keys the
// normalized quaternion built from them. Editing a field keys the row at the
// playhead with the edited value. A clip inside a model shows them read-only.

// The kind a row's fields edit, false for a property row that no longer
// resolves (it has no live type to show). A Rotation row edits three euler
// angles.
@(private = "file")
_pv_row_kind :: proc(ch: ^anim.Animation_Channel) -> (kind: anim.Prop_Kind, ok: bool) {
	if anim.animation_channel_is_property(ch) {
		loc, mok := anim._prop_meta(ch.component, ch.field)
		return loc.kind, mok
	}
	return .Vec3, true
}

// Whether a channel is a transform Rotation row, whose fields show euler
// angles of the stored quaternion.
@(private = "file")
_pv_ch_is_rotation :: proc(ch: ^anim.Animation_Channel) -> bool {
	return !anim.animation_channel_is_property(ch) && ch.path == .Rotation
}

// The euler angles (degrees) a Rotation row or key shows for quaternion `q`.
@(private = "file")
_pv_rot_to_euler :: proc(q: [4]f32) -> [3]f32 {
	return engine.quat_to_euler_xyz(q)
}

// The normalized quaternion a Rotation row or key keys for euler angles `e`.
@(private)
_pv_rot_from_euler :: proc(e: [3]f32) -> [4]f32 {
	q := engine.quat_from_euler_xyz(e.x, e.y, e.z)
	if l := linalg.length(q); l > 0.0001 do q = (1.0 / l) * q
	return q
}

@(private = "file")
_pv_kind_lanes :: proc(kind: anim.Prop_Kind) -> int {
	switch kind {
	case .Vec2: return 2
	case .Vec3: return 3
	case .Vec4: return 4
	case .F32, .Bool, .Int, .Ref, .Text:
	}
	return 1
}

// A key value as float lanes, an int in the first lane. A reference or string
// has none.
@(private = "file")
_pv_value_floats :: proc(v: anim.Channel_Value) -> [4]f32 {
	#partial switch x in v {
	case [4]f32: return x
	case i64:    return {f32(x), 0, 0, 0}
	}
	return {}
}

// A key value as an int: the first lane rounded for floats.
@(private = "file")
_pv_value_int :: proc(v: anim.Channel_Value) -> i64 {
	#partial switch x in v {
	case i64:    return x
	case [4]f32: return i64(math.round(x.x))
	}
	return 0
}

// A key value as read-only text, for a key of an int row in the footer: an int
// in decimal, a reference as its guid's first 8 digits (":local id" for a
// sub-asset, "None" when empty), a string as it is. Temp-allocated.
@(private = "file")
_pv_value_text :: proc(v: anim.Channel_Value) -> string {
	switch x in v {
	case [4]f32: return fmt.tprintf("%.2f", x.x)
	case i64:    return fmt.tprintf("%d", x)
	case engine.PPtr:
		if engine.asset_guid_is_empty(x.guid) do return "None"
		g := uuid.to_string(uuid.Identifier(x.guid), context.temp_allocator)[:8]
		if x.local_id != 0 do return fmt.tprintf("%s:%d", g, x.local_id)
		return g
	case string: return x
	}
	unreachable()
}

// The struct tag of the field a property row animates, "" when the row does
// not resolve. A reference row's picker reads its `ext:` and `ref:` tags.
@(private = "file")
_pv_field_tag :: proc(ch: ^anim.Animation_Channel) -> reflect.Struct_Tag {
	guid, gerr := uuid.read(ch.component)
	if gerr != nil do return ""
	cur, ok := engine.get_typeid_by_guid_ok(guid)
	if !ok do return ""
	tag: reflect.Struct_Tag
	rest := ch.field
	for len(rest) > 0 {
		key := rest
		if dot := strings.index_byte(rest, '.'); dot >= 0 {
			key = rest[:dot]
			rest = rest[dot + 1:]
		} else {
			rest = ""
		}
		names := reflect.struct_field_names(cur)
		types := reflect.struct_field_types(cur)
		tags := reflect.struct_field_tags(cur)
		found := false
		for name, i in names {
			if name != key do continue
			cur = types[i].id
			tag = tags[i]
			found = true
			break
		}
		if !found do return ""
	}
	return tag
}

// The field of a string or reference value, `w` wide at the cursor. A string
// shows a text field: Enter returns the typed text (temp-allocated), a click
// elsewhere drops it. A reference shows the inspector's asset picker on a
// copy, filtered by the field's tags: a pick or a drop returns the new value.
@(private = "file")
_pv_discrete_field :: proc(ch: ^anim.Animation_Channel, kind: anim.Prop_Kind, value: anim.Channel_Value, w: f32) -> (edited: anim.Channel_Value, ok: bool) {
	#partial switch kind {
	case .Text:
		buf: [256]u8
		if s, is_str := value.(string); is_str do copy(buf[:len(buf) - 1], s)
		im.SetNextItemWidth(w)
		// The field shows the value until it is typed into, then keeps its own
		// text until Enter (or Escape, editor/text_input.odin) commits it.
		if im.InputText("##anim_str", cstring(raw_data(buf[:])), uint(len(buf)), {.EnterReturnsTrue}) {
			return strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator), true
		}
	case .Ref:
		orig, _ := value.(engine.PPtr)
		picked := orig
		prev_tags := inspector.field_tags_set(_pv_field_tag(ch))
		defer inspector.field_tags_restore(prev_tags)
		// The picker sizes its value button to the remaining width, so the
		// width past this field counts as trailing.
		prev_trailing := inspector.current_field_trailing_w
		inspector.current_field_trailing_w = max(im.GetContentRegionAvail().x - w, 0)
		defer inspector.current_field_trailing_w = prev_trailing
		// The picker flags the inspector as changed. The flag belongs to the
		// inspector's own rows, so this draw leaves it as it found it.
		prev_changed := inspector.consume_inspector_changed()
		inspector.draw_pptr_property(&picked, typeid_of(engine.PPtr), "##anim_ref")
		inspector.consume_inspector_changed()
		if prev_changed do inspector.mark_inspector_changed()
		if picked != orig do return picked, true
	}
	return {}, false
}

// The width a row's value fields take at the column's right edge.
@(private = "file")
_pv_row_values_w :: proc(ch: ^anim.Animation_Channel) -> f32 {
	kind, ok := _pv_row_kind(ch)
	if !ok do return 0
	if kind == .Bool do return _pv_row_field_h()
	if kind == .Ref || kind == .Text do return 3 * _ANIM_VAL_W + 2 * _ANIM_VAL_GAP
	n := f32(_pv_kind_lanes(kind))
	return n * _ANIM_VAL_W + (n - 1) * _ANIM_VAL_GAP
}

// Frame padding that fits a field inside one row.
@(private = "file")
_pv_row_pad_y :: proc() -> f32 {
	return max((_ANIM_ROW_H - 2 - im.GetFontSize()) * 0.5, 0)
}

@(private = "file")
_pv_row_field_h :: proc() -> f32 {
	return im.GetFontSize() + 2 * _pv_row_pad_y()
}

// Keys row `row` at the playhead with `value`: the key already at the playhead
// takes it, else a key is added there. One undo step, or part of the open row
// value gesture.
@(private)
_pv_row_key :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, row: int, value: anim.Channel_Value) {
	_pv_add_key(doc, clip, row, _pv.time, value)
}

// A drag on a row value spans frames: the document session stays open from the
// first change until no item is active, so the drag is one undo step.
@(private = "file")
_pv_row_gesture: bool

@(private = "file")
_pv_row_gesture_end :: proc() {
	_pv_row_gesture = false
	_pv_edit_held = false
	doc, clip := _pv_doc()
	if doc == nil || clip == nil {
		undo.edit_session_end(&_pv_session)
		return
	}
	// A rotation key renormalizes at commit, as the key footer does.
	if _pv_sel_valid(clip) {
		ch := &clip.channels[_av.sel_ch]
		if !anim.animation_channel_is_property(ch) && ch.path == .Rotation do _pv_normalize_rot_key(ch, _av.sel_key)
	}
	_pv_edit_commit(doc)
}

// The value fields, right-aligned in the property column. Submitted after the
// mode handlers, which read the sheet button as the last item. The sheet
// button allows overlap, so a field under the pointer takes the hover and the
// press: the sheet's press logic (row selection, box select) does not run for
// a click on a field, and typing into it is not interrupted.
@(private = "file")
_pv_draw_row_values :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, rows: []Sheet_Row, rows_y, left_x1: f32) {
	field_h := _pv_row_field_h()
	im.PushStyleVarImVec2(.FramePadding, im.Vec2{3, _pv_row_pad_y()})
	defer im.PopStyleVar(1)
	im.BeginDisabled(doc == nil)
	defer im.EndDisabled()

	for r, row in rows {
		if r.kind != .Channel do continue
		i := r.ch
		ch := &clip.channels[i]
		kind, ok := _pv_row_kind(ch)
		if !ok do continue
		n := _pv_kind_lanes(kind)
		ry := rows_y + f32(row) * _ANIM_ROW_H + (_ANIM_ROW_H - field_h) * 0.5
		x := left_x1 - _pv_row_values_w(ch) - 4
		sampled := anim._animation_channel_sample_value(ch, _pv.time)
		if kind == .Ref || kind == .Text {
			im.PushIDInt(i32(i))
			im.SetCursorScreenPos(im.Vec2{x, ry})
			edited, ok := _pv_discrete_field(ch, kind, sampled, _pv_row_values_w(ch))
			im.PopID()
			if ok {
				// A new key's string, and any array the key grows, live in
				// the document, as recording keys them.
				context.allocator = inspector.doc_alloc()
				_pv_row_key(doc, clip, i, edited)
			}
			continue
		}
		v := _pv_value_floats(sampled)
		iv := _pv_value_int(sampled)
		rot := _pv_ch_is_rotation(ch)
		euler: [3]f32
		if rot do euler = _pv_rot_to_euler(v)
		changed := false
		im.PushIDInt(i32(i))
		for c in 0 ..< n {
			im.PushIDInt(i32(c))
			im.SetCursorScreenPos(im.Vec2{x + f32(c) * (_ANIM_VAL_W + _ANIM_VAL_GAP), ry})
			im.SetNextItemWidth(_ANIM_VAL_W)
			#partial switch kind {
			case .Bool:
				b := iv != 0
				if im.Checkbox("##v", &b) {
					iv = b ? 1 : 0
					changed = true
				}
			case .Int:
				i32v := i32(clamp(iv, i64(min(i32)), i64(max(i32))))
				if im.DragInt("##v", &i32v, 0.1) {
					iv = i64(i32v)
					changed = true
				}
			case:
				if rot {
					if im.DragFloat("##v", &euler[c], 0.5, 0, 0, "%.1f") do changed = true
				} else if im.DragFloat("##v", &v[c], 0.01, 0, 0, "%.2f") {
					changed = true
				}
			}
			im.PopID()
		}
		im.PopID()
		if changed && rot do v = _pv_rot_from_euler(euler)
		edited: anim.Channel_Value = v
		if kind == .Bool || kind == .Int do edited = iv
		if changed {
			if !_pv_row_gesture {
				_pv_row_gesture = true
				_pv_edit_held = true
			}
			_pv_row_key(doc, clip, i, edited)
		}
	}
	// A typed value lands on the frame its field lets go, a drag ends on
	// release: either way nothing is active any more.
	if _pv_row_gesture && !im.IsAnyItemActive() do _pv_row_gesture_end()
}

// A ruler of seconds across the band at `y` of height `h`: a tick and a label
// at every step, the step the first one at least 55 px wide.
@(private = "file")
_pv_ruler_time :: proc(dl: ^im.DrawList, y, h, tx0, pps, length: f32) {
	steps := [?]f32{0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60}
	step := steps[len(steps) - 1]
	for s in steps do if s * pps >= 55 {
		step = s
		break
	}
	_pv_ruler_ticks(dl, y, h, tx0, pps, length, step, _pv_ruler_minor(step), proc(t: f32) -> cstring { return fmt.ctprintf("%.2f", t) })
}

// The unlabeled marks between two labels: a fifth of the step when the step
// is 1 or 5 of its decade (1 -> 0.2, 5 -> 1, 10 -> 2), half of it when the
// step is 2 (2 -> 1, 20 -> 10). The mark at the step's middle is the taller.
@(private = "file")
_pv_ruler_minor :: proc(step: f32) -> f32 {
	m := step
	for m >= 10 do m /= 10
	for m < 1 do m *= 10
	if abs(m - 2) < 0.01 do return step / 2
	return step / 5
}

// A ruler of frame numbers: the step is a whole number of frames, the first
// at least 55 px wide.
@(private = "file")
_pv_ruler_frames :: proc(dl: ^im.DrawList, y, h, tx0, pps, length, fps: f32) {
	steps := [?]f32{1, 2, 5, 10, 20, 50, 100, 200, 500, 1000}
	frames := steps[len(steps) - 1]
	for s in steps do if s / fps * pps >= 55 {
		frames = s
		break
	}
	_pv_ruler_fps = fps
	// Marks between frame labels are whole frames: every frame under a step of
	// 5, every step/5 or step/2 above.
	minor := frames / fps
	switch {
	case frames >= 5:  minor = _pv_ruler_minor(frames) / fps
	case frames == 2:  minor = 1 / fps
	}
	_pv_ruler_ticks(dl, y, h, tx0, pps, length, frames / fps, minor, proc(t: f32) -> cstring { return fmt.ctprintf("%d", i32(math.round(t * _pv_ruler_fps))) })
}

// The frame rate the frames ruler labels with, set right before its ticks
// draw: the label proc has no context of its own.
@(private = "file")
_pv_ruler_fps: f32

// Ticks and labels along a ruler band: a labeled mark every `step` seconds,
// unlabeled marks every `minor` seconds between them (the one at the step's
// middle taller than the rest), none when they would sit closer than 5 px.
// Marks rise from the band's bottom. The label is drawn at the font size
// that fits the band, so the half bands of Frames and Time stay readable.
@(private = "file")
_pv_ruler_ticks :: proc(dl: ^im.DrawList, y, h, tx0, pps, length, step, minor: f32, label: proc(t: f32) -> cstring) {
	tick_col := im.GetColorU32(.TextDisabled)
	major_h := min(f32(8), h * 0.45)
	size := min(im.GetFontSize(), h - 2)
	text_y := y + (h - size) * 0.5
	for i in 0 ..= int(length / step) {
		t := f32(i) * step
		tx := tx0 + t * pps
		im.DrawList_AddLine(dl, im.Vec2{tx, y + h - major_h}, im.Vec2{tx, y + h}, tick_col, 1)
		im.DrawList_AddTextImFontPtr(dl, im.GetFont(), size, im.Vec2{tx + 3, text_y}, tick_col, label(t))
	}
	if minor <= 0 || minor >= step || minor * pps < 5 do return
	for i in 0 ..= int(length / minor) {
		t := f32(i) * minor
		if abs(math.remainder(t, step)) < minor * 0.5 do continue // a labeled mark
		mid := abs(math.remainder(t, step)) > step * 0.5 - minor * 0.5
		mh := mid ? major_h * 0.66 : major_h * 0.4
		im.DrawList_AddLine(dl, im.Vec2{tx0 + t * pps, y + h - mh}, im.Vec2{tx0 + t * pps, y + h}, tick_col, 1)
	}
}

// --- Dopesheet ------------------------------------------------------------------------

@(private = "file")
_pv_key_hit_x :: proc(times: []f32, mx, tx0, pps: f32) -> int {
	best := -1
	best_d := _ANIM_HIT
	for t, k in times {
		d := abs(tx0 + t * pps - mx)
		if d < best_d {
			best_d = d
			best = k
		}
	}
	return best
}

// The keys an Object row's summary key under `mx` stands for, nil when no
// summary key is there. Temp-allocated.
@(private = "file")
_pv_summary_hit :: proc(clip: ^anim.AnimationClip, target: string, mx, tx0, pps: f32) -> []Sheet_Key {
	times := sheet_object_key_times(clip, target, context.temp_allocator)
	j := _pv_key_hit_x(times, mx, tx0, pps)
	if j < 0 do return nil
	return sheet_object_keys_at(clip, target, times, j, context.temp_allocator)
}

// Per summary time of an Object row: every key it stands for is selected.
// Temp-allocated, parallel to `times`.
@(private = "file")
_pv_summary_selected :: proc(clip: ^anim.AnimationClip, target: string, times: []f32) -> []bool {
	all := make([]bool, len(times), context.temp_allocator)
	if len(_av.sel) == 0 do return all
	for &v in all do v = true
	for &c, ci in clip.channels {
		if c.target != target do continue
		for kt, k in c.times {
			if j := sheet_object_key_index(times, kt); j >= 0 && !_pv_sel_has(ci, k) do all[j] = false
		}
	}
	return all
}

// A summary key: a dimmer diamond with an outline, so it reads apart from a
// property row's keys.
@(private = "file")
_pv_draw_summary_key :: proc(dl: ^im.DrawList, kx, ky: f32, sel: bool) {
	r := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
	top, right, bottom, left := im.Vec2{kx, ky - r}, im.Vec2{kx + r, ky}, im.Vec2{kx, ky + r}, im.Vec2{kx - r, ky}
	fill := sel ? im.GetColorU32(.CheckMark) : im.GetColorU32(.TextDisabled)
	im.DrawList_AddQuadFilled(dl, top, right, bottom, left, fill)
	im.DrawList_AddQuad(dl, top, right, bottom, left, im.GetColorU32(.Text), 1)
}

// Adds the keys of channel `ci` inside the band [rmin, rmax] in x to the
// selection.
@(private = "file")
_pv_box_add_channel :: proc(clip: ^anim.AnimationClip, ci: int, rmin, rmax: im.Vec2, tx0, pps: f32) {
	for t, k in clip.channels[ci].times {
		kx := tx0 + t * pps
		if kx < rmin.x || kx > rmax.x do continue
		_pv_sel_pin()
		append(&_av.sel, _Key_Ref{ci, k})
	}
}

@(private = "file")
_pv_sheet_dopesheet :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	rows: []Sheet_Row,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	hovered: bool,
	mp: im.Vec2,
	row_at: int,
) {
	// Row stripes + keys. An Object row shows a summary key at every time any
	// of its channels has one, the hidden ones included.
	for r, i in rows {
		ry := rows_y + f32(i) * _ANIM_ROW_H
		ky := ry + _ANIM_ROW_H * 0.5
		if r.kind == .Object {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.6))
			times := sheet_object_key_times(clip, r.target, context.temp_allocator)
			sel := _pv_summary_selected(clip, r.target, times)
			for t, j in times do _pv_draw_summary_key(dl, tx0 + t * pps, ky, sel[j])
			continue
		}
		if i % 2 == 1 {
			im.DrawList_AddRectFilled(dl, im.Vec2{x0, ry}, im.Vec2{x1, ry + _ANIM_ROW_H}, im.GetColorU32(.FrameBg, 0.25))
		}
		for t, k in clip.channels[r.ch].times {
			kx := tx0 + t * pps
			sel := _pv_sel_has(r.ch, k)
			col := sel ? im.GetColorU32(.CheckMark) : im.GetColorU32(.Text)
			kr := sel ? _ANIM_KEY_R + 1 : _ANIM_KEY_R
			im.DrawList_AddQuadFilled(dl,
				im.Vec2{kx, ky - kr}, im.Vec2{kx + kr, ky},
				im.Vec2{kx, ky + kr}, im.Vec2{kx - kr, ky}, col)
		}
	}

	// The row under the pointer: an Object row, or a property row's channel.
	obj_row := row_at >= 0 && rows[row_at].kind == .Object
	row_ch := row_at >= 0 && !obj_row ? rows[row_at].ch : -1

	if im.IsItemActivated() {
		in_canvas := mp.x >= x0
		if obj_row {
			// A summary key selects every key it stands for and drags them, as
			// a property row's key does. The name selects nothing: its arrow
			// is the sheet's (collapse), the rest of it is inert.
			keys: []Sheet_Key
			if in_canvas do keys = _pv_summary_hit(clip, rows[row_at].target, mp.x, tx0, pps)
			switch {
			case len(keys) > 0 && _pv_additive():
				_pv_sel_toggle_keys(keys)
			case len(keys) > 0:
				if !_pv_sel_has_all(keys) do _pv_sel_set_keys(keys)
				_av.sel_ch = keys[0].ch
				_av.sel_key = keys[0].key
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = -1)
			case in_canvas:
				// Empty canvas on an Object row: rubber-band, the channel stays.
				_av.sel_key = -1
				clear(&_av.sel)
				_av.box = true
				_av.box_from = mp
			}
		} else {
			k := -1
			if in_canvas && row_ch >= 0 do k = _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps)
			switch {
			case k >= 0 && _pv_additive():
				// Add to or drop from the selection, no drag: a modifier click is
				// for building a set, not moving it.
				_pv_sel_toggle(row_ch, k)
			case k >= 0:
				// Dragging a key that is already selected moves the whole
				// selection; grabbing an unselected one selects just it.
				if !_pv_sel_has(row_ch, k) do _pv_sel_set(row_ch, k)
				_av.sel_ch = row_ch
				_av.sel_key = k
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = -1)
			case in_canvas:
				// Empty canvas, on a track row or below the last one: rubber-band
				// a new selection. The row under the press only sets the channel
				// when there is one, so a band started below the tracks leaves
				// the current channel alone.
				if row_ch >= 0 do _av.sel_ch = row_ch
				_av.sel_key = -1
				clear(&_av.sel)
				_av.box = true
				_av.box_from = mp
			case row_ch >= 0:
				// Left panel: pick the channel.
				_av.sel_ch = row_ch
				_av.sel_key = -1
				clear(&_av.sel)
			}
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		// Right-clicking outside the selection retargets it, so the menu
		// always acts on what is under the cursor.
		if obj_row {
			if keys := _pv_summary_hit(clip, rows[row_at].target, mp.x, tx0, pps); len(keys) > 0 {
				if !_pv_sel_has_all(keys) do _pv_sel_set_keys(keys)
				_av.sel_ch = keys[0].ch
				_av.sel_key = keys[0].key
				im.OpenPopup("##anim_key_ctx")
			}
		} else if row_ch >= 0 {
			if k := _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps); k >= 0 {
				if !_pv_sel_has(row_ch, k) do _pv_sel_set(row_ch, k)
				_av.sel_ch = row_ch
				_av.sel_key = k
				im.OpenPopup("##anim_key_ctx")
			}
		}
	}
	// Double-click on empty canvas of a property row: add a key there
	// (sampled, shape-preserving). An Object row has no channel to key.
	if hovered && row_ch >= 0 && mp.x >= x0 && im.IsMouseDoubleClicked(.Left) {
		if _pv_key_hit_x(clip.channels[row_ch].times[:], mp.x, tx0, pps) < 0 {
			_av.box = false // the press that opened the band was this click
			_pv_add_key(doc, clip, row_ch, _pv_snap_time(clip, (mp.x - tx0) / pps))
		}
	}

	// --- Box select: every key inside the band, across rows. An Object row in
	// the band takes the keys of all its channels, hidden ones included, and
	// its property rows then add nothing more.
	if _av.box {
		rmin := im.Vec2{min(_av.box_from.x, mp.x), min(_av.box_from.y, mp.y)}
		rmax := im.Vec2{max(_av.box_from.x, mp.x), max(_av.box_from.y, mp.y)}
		im.DrawList_AddRectFilled(dl, rmin, rmax, im.GetColorU32(.Header, 0.35))
		im.DrawList_AddRect(dl, rmin, rmax, im.GetColorU32(.CheckMark))

		clear(&_av.sel)
		object_in_band := false // the Object row the rows below belong to
		for r, i in rows {
			ky := rows_y + f32(i) * _ANIM_ROW_H + _ANIM_ROW_H * 0.5
			in_band := ky >= rmin.y && ky <= rmax.y
			if r.kind == .Object {
				object_in_band = in_band
				if !in_band do continue
				for &c, ci in clip.channels {
					if c.target == r.target do _pv_box_add_channel(clip, ci, rmin, rmax, tx0, pps)
				}
				continue
			}
			if in_band && !object_in_band do _pv_box_add_channel(clip, r.ch, rmin, rmax, tx0, pps)
		}
		// Primary is the first key the band caught, so the value footer has
		// something to edit.
		if len(_av.sel) > 0 {
			_av.sel_ch = _av.sel[0].ch
			_av.sel_key = _av.sel[0].key
		} else {
			_av.sel_key = -1
		}
		if !im.IsMouseDown(.Left) do _av.box = false
	}
}

// Opens the undo session for a key drag and records where every selected key
// started, so the move is one delta applied to the group.
@(private = "file")
_pv_drag_begin :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, from: f32, comp: int) {
	if doc == nil do return // read-only: the press only selects
	_pv_edit_begin(doc)
	_av.drag_key = true
	_av.drag_press = im.GetMousePos()
	_av.drag_live = false
	_av.drag_comp = comp
	_av.drag_from = _pv_snap_time(clip, from)
	clear(&_av.drag_t0)
	for r in _av.sel do append(&_av.drag_t0, clip.channels[r.ch].times[r.key])
}

// --- Curves ---------------------------------------------------------------------------

// Value range of the curve area this frame (set during draw, read by the drag
// update). Range follows the selected channel's keys and its Free keys'
// tangent handles, with 10% padding.
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

// Pixels per value unit on the curve area's y axis.
@(private = "file")
_pv_curve_vpx :: proc(body_h: f32) -> f32 {
	return max(body_h - 12, 1) / max(_curve_vmax - _curve_vmin, 0.0001)
}

// Whether the curve view draws tangent handles for a channel: a float row
// whose keys can be Free (a Rotation row slerps and has no tangents).
@(private = "file")
_pv_curve_has_handles :: proc(ch: ^anim.Animation_Channel) -> bool {
	return .Free in channel_modes_allowed(ch)
}

// The screen point of a tangent handle of key `k`, lane `c`: the out handle
// when `out`, else the in handle. `tin` and `tout` are the key's tangents.
@(private = "file")
_pv_tan_handle_pos :: proc(key_pt: im.Vec2, tin, tout: [4]f32, c: int, out: bool, pps, vpx: f32) -> im.Vec2 {
	if out {
		d := tangent_handle_offset(tout[c], pps, vpx, _ANIM_TAN_LEN)
		return {key_pt.x + d.x, key_pt.y + d.y}
	}
	d := tangent_handle_offset(tin[c], pps, vpx, _ANIM_TAN_LEN)
	return {key_pt.x - d.x, key_pt.y - d.y}
}

// Ends a tangent handle drag: records the undo step, or drops the session
// when the key it edited went away.
@(private = "file")
_pv_tan_drag_end :: proc(doc: ^inspector.Asset_Doc, commit: bool) {
	_av.drag_tan = false
	if commit && doc != nil {
		_pv_edit_commit(doc)
	} else {
		undo.edit_session_abort(&_pv_session)
	}
}

@(private = "file")
_pv_sheet_curves :: proc(
	doc: ^inspector.Asset_Doc,
	clip: ^anim.AnimationClip,
	dl: ^im.DrawList,
	rows: []Sheet_Row,
	rows_y, body_h, x0, x1, tx0, pps: f32,
	mp: im.Vec2,
	row_at: int,
) {
	// Left-panel click on a property row selects the channel whose curves
	// show. An Object row plots nothing.
	if im.IsItemActivated() && mp.x < x0 && row_at >= 0 && rows[row_at].kind == .Channel {
		_av.sel_ch = rows[row_at].ch
		_av.sel_key = -1
		clear(&_av.sel)
	}

	if _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels) {
		if _av.drag_tan do _pv_tan_drag_end(doc, false)
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "Select a property to edit its curves.")
		return
	}
	ch := &clip.channels[_av.sel_ch]
	if !anim.animation_channel_is_float(ch) {
		if _av.drag_tan do _pv_tan_drag_end(doc, false)
		im.DrawList_AddText(dl, im.Vec2{x0 + 12, rows_y + 8}, im.GetColorU32(.TextDisabled), "This property holds discrete keys: it has no curve.")
		return
	}
	vals := anim.animation_channel_floats(ch)
	ncomp := _pv_ch_ncomp(ch)
	handles := _pv_curve_has_handles(ch)

	// Freeze the value range while dragging — a range that follows the edited
	// value makes the curve chase the cursor.
	if !_av.drag_key && !_av.drag_tan {
		vmin, vmax := max(f32), min(f32)
		for v in vals {
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
		// The range takes in the Free keys' handle points too, so a steep
		// handle on a flat curve is not clipped away. A handle's value depends
		// on the range it is drawn in, so the range settles over a few passes.
		if handles {
			for _ in 0 ..< 3 {
				vpx := _pv_curve_vpx(body_h)
				hmin, hmax := vmin, vmax
				for k in 0 ..< len(ch.times) {
					if anim._animation_key_mode(ch, k) != .Free do continue
					tin, tout := anim._animation_key_tangents(ch, vals[:], k)
					for c in 0 ..< ncomp {
						dout := tangent_handle_offset(tout[c], pps, vpx, _ANIM_TAN_LEN)
						din := tangent_handle_offset(tin[c], pps, vpx, _ANIM_TAN_LEN)
						hi_v := vals[k][c] - dout.y / vpx
						lo_v := vals[k][c] + din.y / vpx
						hmin = min(hmin, hi_v, lo_v)
						hmax = max(hmax, hi_v, lo_v)
					}
				}
				hpad := (hmax - hmin) * 0.1
				_curve_vmin, _curve_vmax = hmin - hpad, hmax + hpad
			}
		}
	}
	vpx := _pv_curve_vpx(body_h)

	// A tangent handle drag: the dragged tangent follows the pointer, Shift
	// sets the other side to the same slope (a smooth joint). Updated before
	// drawing, so the curve shows this frame's tangent.
	if _av.drag_tan {
		k, c := _av.tan_key, _av.tan_comp
		switch {
		case doc == nil || !handles || k < 0 || k >= len(ch.times) || c >= ncomp || anim._animation_key_mode(ch, k) != .Free:
			_pv_tan_drag_end(doc, false)
		case im.IsMouseDown(.Left):
			key_pt := im.Vec2{tx0 + ch.times[k] * pps, _pv_curve_v_to_y(vals[k][c], rows_y, body_h)}
			m := tangent_from_handle({mp.x - key_pt.x, mp.y - key_pt.y}, pps, vpx, _av.tan_out)
			tin, tout := anim._animation_key_tangents(ch, vals[:], k)
			joint := im.GetIO().KeyShift
			if _av.tan_out {
				tout[c] = m
				if joint do tin[c] = m
			} else {
				tin[c] = m
				if joint do tout[c] = m
			}
			{
				// A key past the end of `tangents` grows it, in the document.
				context.allocator = inspector.doc_alloc()
				channel_set_key_tangents(ch, k, tin, tout)
			}
			_pv_mark_edited(doc)
		case:
			_pv_tan_drag_end(doc, true)
		}
	}

	// The handle under the pointer: the dragged one, else the nearest within
	// the hit radius. Handles take a press before keys do.
	hov_k, hov_c, hov_out := -1, -1, false
	if _av.drag_tan {
		hov_k, hov_c, hov_out = _av.tan_key, _av.tan_comp, _av.tan_out
	} else if handles && im.IsItemHovered() && mp.x >= x0 {
		best_d := _ANIM_HIT
		for t, k in ch.times {
			if anim._animation_key_mode(ch, k) != .Free do continue
			tin, tout := anim._animation_key_tangents(ch, vals[:], k)
			for c in 0 ..< ncomp {
				key_pt := im.Vec2{tx0 + t * pps, _pv_curve_v_to_y(vals[k][c], rows_y, body_h)}
				for out in ([2]bool{false, true}) {
					hp := _pv_tan_handle_pos(key_pt, tin, tout, c, out, pps, vpx)
					d := max(abs(hp.x - mp.x), abs(hp.y - mp.y))
					if d < best_d {
						best_d = d
						hov_k, hov_c, hov_out = k, c, out
					}
				}
			}
		}
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
		// Tangent handles of the Free keys, under the key squares. The
		// hovered or dragged handle draws brighter.
		if handles {
			bright := im.GetColorU32ImVec4(linalg.lerp(comp_cols[c], im.Vec4{1, 1, 1, 1}, 0.55))
			dim := im.GetColorU32ImVec4(im.Vec4{comp_cols[c].x, comp_cols[c].y, comp_cols[c].z, 0.75})
			for t, k in ch.times {
				if anim._animation_key_mode(ch, k) != .Free do continue
				tin, tout := anim._animation_key_tangents(ch, vals[:], k)
				key_pt := im.Vec2{tx0 + t * pps, _pv_curve_v_to_y(vals[k][c], rows_y, body_h)}
				for out in ([2]bool{false, true}) {
					hp := _pv_tan_handle_pos(key_pt, tin, tout, c, out, pps, vpx)
					hot := k == hov_k && c == hov_c && out == hov_out
					hcol := hot ? bright : dim
					im.DrawList_AddLine(dl, key_pt, hp, hcol, 1)
					im.DrawList_AddCircleFilled(dl, hp, hot ? _ANIM_TAN_R + 1 : _ANIM_TAN_R, hcol)
				}
			}
		}
		for t, k in ch.times {
			kx := tx0 + t * pps
			ky := _pv_curve_v_to_y(vals[k][c], rows_y, body_h)
			sel := k == _av.sel_key && c == _av.drag_comp
			r := sel ? f32(4) : f32(3)
			im.DrawList_AddRectFilled(dl, im.Vec2{kx - r, ky - r}, im.Vec2{kx + r, ky + r}, sel ? im.GetColorU32(.CheckMark) : col)
		}
	}
	im.DrawList_PopClipRect(dl)

	// Press on a tangent handle: drag edits that tangent. It selects the key,
	// and a read-only clip only selects.
	if im.IsItemActivated() && mp.x >= x0 && hov_k >= 0 && !_av.drag_tan {
		if !_pv_sel_has(_av.sel_ch, hov_k) do _pv_sel_set(_av.sel_ch, hov_k)
		_av.sel_key = hov_k
		if doc != nil {
			_pv_edit_begin(doc)
			_av.drag_tan = true
			_av.tan_key, _av.tan_comp, _av.tan_out = hov_k, hov_c, hov_out
		}
	} else if im.IsItemActivated() && mp.x >= x0 {
		// Press on a key square: drag edits (time, value[comp]).
		best_k, best_c := -1, -1
		best_d := _ANIM_HIT
		for t, k in ch.times {
			kx := tx0 + t * pps
			for c in 0 ..< ncomp {
				ky := _pv_curve_v_to_y(vals[k][c], rows_y, body_h)
				d := max(abs(kx - mp.x), abs(ky - mp.y))
				if d < best_d {
					best_d = d
					best_k, best_c = k, c
				}
			}
		}
		if best_k >= 0 {
			if _pv_additive() {
				_pv_sel_toggle(_av.sel_ch, best_k)
			} else {
				// As in the dopesheet: dragging a selected key moves the
				// group, an unselected one becomes the selection.
				if !_pv_sel_has(_av.sel_ch, best_k) do _pv_sel_set(_av.sel_ch, best_k)
				_av.sel_key = best_k
				_pv_drag_begin(doc, clip, (mp.x - tx0) / pps, comp = best_c)
			}
		} else {
			_av.sel_key = -1
			clear(&_av.sel)
		}
	}
	if im.IsItemClicked(.Right) && mp.x >= x0 {
		if k := _pv_key_hit_x(ch.times[:], mp.x, tx0, pps); k >= 0 {
			if !_pv_sel_has(_av.sel_ch, k) do _pv_sel_set(_av.sel_ch, k)
			_av.sel_key = k
			im.OpenPopup("##anim_key_ctx")
		}
	}
}

// --- Selected-key footer ----------------------------------------------------------------

@(private = "file")
_pv_draw_key_footer :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) {
	ch := &clip.channels[_av.sel_ch]
	k := _av.sel_key

	// A read-only clip shows the key's values without letting them change.
	im.BeginDisabled(doc == nil)
	defer im.EndDisabled()

	im.AlignTextToFramePadding()
	im.TextUnformatted(fmt.ctprintf("Key %d   t", k))
	im.SameLine()
	im.SetNextItemWidth(70)
	lo, hi := _pv_drag_time_bounds(ch, k, clip.length)
	_pv_field_undo(doc, clip, im.DragFloat("##anim_key_t", &ch.times[k], 0.002, lo, hi, "%.3f"))
	im.SameLine()
	_pv_draw_mode_combo(doc, clip, ch, k)

	// A key of a string row shows a text field and a key of a reference row
	// the asset picker, both setting this key's value. A key of an int row,
	// or of a row that no longer resolves, shows its value as text.
	if !anim.animation_channel_is_float(ch) {
		im.SameLine()
		kind, kok := _pv_row_kind(ch)
		if kok && (kind == .Ref || kind == .Text) {
			if v, edited := _pv_discrete_field(ch, kind, anim.animation_channel_value(ch, k), 200); edited {
				_pv_set_key_value(doc, clip, _av.sel_ch, k, v)
			}
		} else {
			im.TextUnformatted(fmt.ctprintf("%s", _pv_value_text(anim.animation_channel_value(ch, k))))
		}
	}

	// A rotation key shows three euler angles, written back as a quaternion.
	if _pv_ch_is_rotation(ch) {
		vals := anim.animation_channel_floats(ch)
		euler := _pv_rot_to_euler(vals[k])
		axis_names := [3]cstring{"x", "y", "z"}
		for c in 0 ..< 3 {
			im.SameLine()
			im.TextUnformatted(axis_names[c])
			im.SameLine()
			im.SetNextItemWidth(70)
			changed := im.DragFloat(fmt.ctprintf("##anim_key_e%d", c), &euler[c], 0.5, 0, 0, "%.1f")
			// Opened before the write, so the session holds the key from
			// before this frame's change.
			if im.IsItemActivated() do _pv_edit_begin(doc)
			if changed do vals[k] = _pv_rot_from_euler(euler)
			_pv_field_undo(doc, clip, changed)
		}
	}

	ncomp := _pv_ch_is_rotation(ch) || !anim.animation_channel_is_float(ch) ? 0 : _pv_ch_ncomp(ch)
	comp_names := [4]cstring{"x", "y", "z", "w"}
	for c in 0 ..< ncomp {
		im.SameLine()
		im.TextUnformatted(comp_names[c])
		im.SameLine()
		im.SetNextItemWidth(70)
		_pv_field_undo(doc, clip, im.DragFloat(fmt.ctprintf("##anim_key_v%d", c), &anim.animation_channel_floats(ch)[k][c], 0.01))
	}

	im.SameLine()
	im.BeginDisabled(len(ch.times) <= 1)
	if im.Button(len(_av.sel) > 1 ? fmt.ctprintf("Delete %d Keys", len(_av.sel)) : "Delete Key") {
		_pv_delete_key(doc, clip)
	}
	im.EndDisabled()
}

// --- Preview apply/restore (main loop hooks) --------------------------------------------

// A fingerprint of the component's authored state tree, so the preview graph
// rebuilds when it is edited while previewing.
@(private = "file")
_pv_authored_sig :: proc(a: ^anim.Animation) -> u64 {
	sig := u64(0xcbf29ce484222325)
	_pv_sig_mix(&sig, a.clip)
	for &l in a.layers {
		sig ~= 0x9e37
		for &e in l.entries {
			// Structure too, not just the clip set: moving a clip into a blend
			// changes the graph's shape without changing which clips it holds.
			sig = (sig ~ u64(u32(e.id))) * 0x100000001b3
			sig = (sig ~ u64(u32(e.parent))) * 0x100000001b3
			if c, is_clip := e.kind.(anim.Animation_Entry_Clip); is_clip do _pv_sig_mix(&sig, c.clip)
		}
	}
	return sig
}

@(private = "file")
_pv_sig_mix :: proc(sig: ^u64, g: engine.PPtr) {
	// Asset_GUID is a distinct [16]u8: transmute, not cast — an array type
	// conversion is not a cast in Odin.
	bytes := transmute([16]u8)g.guid
	for b in bytes do sig^ = (sig^ ~ u64(b)) * 0x100000001b3
	sig^ = (sig^ ~ u64(g.local_id)) * 0x100000001b3
}

// The scrub preview evaluates the component's FULL authored graph — every
// state, blend children under their blend's mixer — with the scrubbed clip at
// weight 1 and everything else at 0. The zero-weight nodes cost nothing (the
// evaluator skips them) and change nothing in the pose, and because the graph
// comes from the same builder the driver uses, the Playable Graph window shows
// the topology the component actually plays, with live weights.
//
// A clip inside a blend is lit along its whole chain: the clip under the
// blend's mixer, and that mixer under the layer mixer. Lighting only the leaf
// would leave its blend at 0 under the layer, and nothing would reach the pose.
@(private = "file")
_pv_build_graph :: proc(a: ^anim.Animation) {
	leaves := make([dynamic]anim.Animation_Authored_Leaf, context.temp_allocator)
	anim.animation_graph_build_authored(a, &_pv.graph, _pv.owner, 0, &leaves)
	_pv.node = {}

	if _pv.entry != 0 {
		// A state lights its whole chain: for a blend that is its mixer under
		// the layer, with the 1D rule weighting the children every frame.
		if _pv.entry_kids == nil do _pv.entry_kids = make([dynamic]anim.Animation_Blend_Child)
		clear(&_pv.entry_kids)
		for l in leaves {
			if l.entry != _pv.entry do continue
			_pv.entry_top, _pv.entry_layer = l.top, l.layer
			append(&_pv.entry_kids, l.child)
		}
		if _pv.entry_top != {} {
			anim.playable_set_input_weight(&_pv.graph, _pv.entry_layer, _pv.entry_top, 1)
			// A clip state IS its node, so light it under the layer directly.
			// A blend's children are weighted per frame by the 1D rule.
			if len(_pv.entry_kids) == 1 && _pv.entry_kids[0].node == _pv.entry_top {
				_pv.node = _pv.entry_top
			}
		}
		_pv.graph_sig = _pv_authored_sig(a)
		_pv.ready = true
		return
	}

	for l in leaves {
		if l.clip != _pv.clip do continue
		_pv.node = l.node
		anim.playable_set_input_weight(&_pv.graph, l.under, l.node, 1)
		anim.playable_set_input_weight(&_pv.graph, l.layer, l.top, 1)
		break
	}
	_pv.graph_sig = _pv_authored_sig(a)
	_pv.ready = true
}

// Advance the previewed state and write its times into the graph. A blend runs
// on a shared phase at the blended cycle length, exactly as it does when the
// driver plays it — the same two procs do the work in both places.
@(private = "file")
_pv_entry_tick :: proc(a: ^anim.Animation, dt: f32) {
	if _pv.entry_top == {} || len(_pv.entry_kids) == 0 do return

	// A single clip whose node IS the top: an ordinary clip state.
	if _pv.node != {} {
		k := _pv.entry_kids[0]
		if !_pv.entry_done do _pv.entry_clock += dt
		t, done := anim.animation_wrap_time(_pv.entry_clock, k.length, k.wrap)
		if done do _pv.entry_done = true
		if n := anim.playable_node(&_pv.graph, _pv.node); n != nil do n.time = t
		return
	}

	value := anim.animation_blend_get(a, _pv.entry)
	cycle := anim.animation_blend1d_weights(&_pv.graph, _pv.entry_top, _pv.entry_kids[:], value)
	if cycle <= 0 do return
	if !_pv.entry_done do _pv.entry_clock += dt / cycle
	p, done := anim.animation_wrap_time(_pv.entry_clock, 1, _pv.entry_kids[0].wrap)
	if done do _pv.entry_done = true
	anim.animation_blend_sample(&_pv.graph, _pv.entry_kids[:], p)
}

// Apply the preview pose for this frame's scene/game render. Runs in the main
// loop after the window UI set the scrub state, right before the world renders.
animation_preview_apply :: proc() {
	if !_pv.active do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) do _pv_preview_off()
	if _pv.entry == 0 && _pv.clip == {} do _pv_preview_off()
	if !_pv.active {
		_pv_preview_off()
		return
	}
	_, a := engine.transform_get_comp(_pv.owner, anim.Animation)
	if a == nil {
		_pv_preview_off()
		return
	}

	clip: ^anim.AnimationClip
	if _pv.entry == 0 {
		c, ok := anim.animation_clip_load(_pv.clip)
		if !ok do return
		clip = c
	}

	if _pv.ready && _pv.graph_sig != _pv_authored_sig(a) do _pv_teardown()
	if !_pv.ready do _pv_build_graph(a)

	if _pv.entry != 0 {
		_pv_entry_tick(a, im.GetIO().DeltaTime)
	} else if n := anim.playable_node(&_pv.graph, _pv.node); n != nil {
		n.time = clamp(_pv.time, 0, clip.length)
	}

	anim.animation_binding_refresh_defaults(_pv_binding())
	anim.playable_graph_tick(&_pv.graph)
	_pv.applied = true
}

// Restore the authored pose after the scene/game render. The world spends the
// rest of the frame — saves, undo, inspector — at authored values.
animation_preview_restore :: proc() {
	if !_pv.applied do return
	_pv.applied = false
	anim.animation_binding_write_defaults(_pv_binding())
}

// --- Test access -----------------------------------------------------------------------

// Test-only: selects key `key` of row `ch`, replacing the selection, or added
// to it when `add`, as a click and a modifier click on the key do.
animation_view_select_key :: proc(ch, key: int, add := false) {
	if add && !_pv_sel_has(ch, key) {
		_pv_sel_toggle(ch, key)
		return
	}
	_pv_sel_set(ch, key)
}

// Test-only: sets `mode` on every selected key of the shown clip, as the key
// context menu's Mode items and the footer's combo do.
animation_view_set_key_mode :: proc(mode: anim.Key_Mode) {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_keys_set_mode(doc, clip, mode)
}

// Test-only: applies `preset` to every selected key of the shown clip, as the
// key context menu's tangent presets do.
animation_view_apply_preset :: proc(preset: Key_Preset) {
	doc, clip := _pv_doc()
	if doc == nil || clip == nil do return
	_pv_keys_apply_preset(doc, clip, preset)
}

// Test-only: clears the key selection.
animation_view_deselect :: proc() {
	_pv_deselect()
}
