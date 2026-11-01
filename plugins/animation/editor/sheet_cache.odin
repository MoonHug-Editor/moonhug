package animation_editor

// The Animation window's sheet model, derived from the clip once per change
// instead of once per frame: the rows (sheet_rows.odin), each property's
// channels, and what each channel resolves to on its component. It rebuilds
// when the document's edit count (inspector.Asset_Doc.edits, bumped by every
// edit, undo and redo), the clip, or the view's collapse and expand state
// (_Anim_View.view_gen) changes. A clip inside a model has no document and
// never changes, so its model is built once.
//
// Slices into a model stay readable for the rest of the frame after a
// rebuild: a replaced model waits in _Anim_View.sheets_old and is freed at
// the start of the next draw. So code that took `rows` before a menu edited
// the clip reads stale but valid memory until it refreshes.
//
// The selection is channel and key indices, which an edit shifts. Before an
// edit (and whenever it changed) it is also kept as stable keys
// (_Sel_Snap), and after a rebuild it is restored from them: the channel by
// sheet_channel_key and lane set, the key by index.

import "base:runtime"
import "core:fmt"
import "core:encoding/uuid"
import "core:strings"
import engine "moonhug:packages/engine"
import anim "moonhug:packages/animation"
import "moonhug:editor/inspector"

// What a channel resolves to, read many times per row per frame.
_Ch_Meta :: struct {
	kind:     anim.Prop_Kind, // the field's kind, Vec3 for a transform row
	kind_ok:  bool,           // the property resolves on its component type
	width:    int,            // anim.animation_channel_mask_width
	label:    cstring,        // the row label, owned
	resolved: bool,           // the label colour: the property resolves
}

_Sheet :: struct {
	clip:     ^anim.AnimationClip,
	doc:      ^inspector.Asset_Doc,
	edits:    u64,
	view_gen: u64,
	nch:      int,
	base:     [^]anim.Animation_Channel, // the clip's channel storage at build time, compared, never read
	rows:     [dynamic]Sheet_Row,
	// Channel indices of every property, one run per channel: the run of
	// channel i is group_items[group_off[i] : group_off[i] + group_len[i]].
	group_items: [dynamic]int,
	group_off:   [dynamic]int,
	group_len:   [dynamic]int,
	meta:        [dynamic]_Ch_Meta,
}

// A selected key in a form that survives edits.
_Sel_Snap :: struct {
	chan:  string, // sheet_channel_key, owned
	lanes: anim.Lane_Set,
	key:   int,
}

// The model for `clip` in document state `doc`, rebuilt when stale. With no
// window (_av_none, the listener running headless) nothing is cached: a
// temp model is built and returned.
_pv_sheet :: proc(doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) -> ^_Sheet {
	if _av == &_av_none {
		tmp := new(_Sheet, context.temp_allocator)
		_sheet_build(tmp, doc, clip, context.temp_allocator)
		return tmp
	}
	s := &_av.sheet
	if _sheet_current(s, doc, clip) do return s
	// The selection as it stands, while the old indices still hold the
	// channels they name. An edit snapshots at its begin, this covers undo.
	if s.clip == clip && s.nch == len(clip.channels) do _pv_sel_snapshot(clip)
	context.allocator = runtime.default_allocator()
	if s.clip != nil do append(&_av.sheets_old, s^)
	s^ = {}
	_sheet_build(s, doc, clip, runtime.default_allocator())
	_pv_sel_restore(clip)
	return s
}

@(private = "file")
_sheet_current :: proc(s: ^_Sheet, doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip) -> bool {
	if s.clip != clip || s.nch != len(clip.channels) || s.view_gen != _av.view_gen do return false
	if doc == nil do return s.doc == nil
	return s.doc == doc && s.edits == doc.edits
}

@(private = "file")
_sheet_build :: proc(s: ^_Sheet, doc: ^inspector.Asset_Doc, clip: ^anim.AnimationClip, allocator: runtime.Allocator) {
	context.allocator = allocator
	s.clip = clip
	s.doc = doc
	s.edits = doc != nil ? doc.edits : 0
	s.view_gen = _av.view_gen
	s.nch = len(clip.channels)
	s.base = raw_data(clip.channels[:])
	n := len(clip.channels)
	s.group_items = make([dynamic]int, 0, n)
	s.group_off = make([dynamic]int, n)
	s.group_len = make([dynamic]int, n)
	s.meta = make([dynamic]_Ch_Meta, n)
	// Groups: each property once, its channels share the run.
	done := make([]bool, n, context.temp_allocator)
	for i in 0 ..< n {
		if done[i] do continue
		run := anim.animation_clip_property_channels(clip, i, context.temp_allocator)
		off := len(s.group_items)
		append(&s.group_items, ..run)
		for ci in run {
			s.group_off[ci] = off
			s.group_len[ci] = len(run)
			done[ci] = true
		}
	}
	for &c, i in clip.channels do s.meta[i] = _sheet_meta(&c)
	rows := sheet_rows(clip, _av.collapsed, _av.expanded, context.temp_allocator)
	s.rows = make([dynamic]Sheet_Row, len(rows))
	copy(s.rows[:], rows)
}

@(private = "file")
_sheet_meta :: proc(ch: ^anim.Animation_Channel) -> _Ch_Meta {
	m := _Ch_Meta{kind = .Vec3, kind_ok = true, resolved = true}
	if anim.animation_channel_is_property(ch) {
		loc, mok := anim._prop_meta(ch.component, ch.field)
		m.kind = loc.kind
		m.kind_ok = mok
		m.resolved = mok
		comp_name := "?"
		if guid, gerr := uuid.read(ch.component); gerr == nil {
			if tid, ok := engine.get_typeid_by_guid_ok(guid); ok {
				comp_name = fmt.tprintf("%v", tid)
				if dot := strings.last_index_byte(comp_name, '.'); dot >= 0 do comp_name = comp_name[dot + 1:]
			}
		}
		m.label = strings.clone_to_cstring(fmt.tprintf("%s.%s", comp_name, ch.field))
	} else {
		// An Euler row is the rotation too, in another form.
		m.label = strings.clone_to_cstring(ch.path == .Euler ? "Rotation" : fmt.tprintf("%v", ch.path))
	}
	m.width = anim.animation_channel_mask_width(ch)
	return m
}

_sheet_free :: proc(s: ^_Sheet) {
	context.allocator = runtime.default_allocator()
	for m in s.meta do delete(m.label)
	delete(s.meta)
	delete(s.rows)
	delete(s.group_items)
	delete(s.group_off)
	delete(s.group_len)
	s^ = {}
}

// Frees the models replaced during the last frame.
_sheets_old_free :: proc(av: ^_Anim_View) {
	for &old in av.sheets_old do _sheet_free(&old)
	clear(&av.sheets_old)
}

// The model is current between edits: every edit rebuilds it at its commit
// (_pv_edit_commit) and every draw starts with _pv_sheet, so the readers
// below only guard against a clip they were not built from. They never
// read the model's document, which may be closed between frames.

// The channels of the property channel `ch` animates, from the model when
// it is built from `clip`, else computed (temp).
_pv_group :: proc(clip: ^anim.AnimationClip, ch: int) -> []int {
	s := &_av.sheet
	if s.clip == clip && s.nch == len(clip.channels) && ch >= 0 && ch < len(s.group_off) {
		return s.group_items[s.group_off[ch]:s.group_off[ch] + s.group_len[ch]]
	}
	return anim.animation_clip_property_channels(clip, ch, context.temp_allocator)
}

// What channel `ch` resolves to, from the model when `ch` is one of its
// clip's channels and the model is current, else computed (temp label).
_pv_meta :: proc(ch: ^anim.Animation_Channel) -> _Ch_Meta {
	s := &_av.sheet
	if s.base != nil && len(s.meta) == s.nch && ch >= s.base && ch < s.base[s.nch:] {
		idx := int(uintptr(ch) - uintptr(s.base)) / size_of(anim.Animation_Channel)
		return s.meta[idx]
	}
	m := _sheet_meta(ch)
	// Computed outside the model: the label is temp, freed with the frame.
	label := strings.clone_to_cstring(string(m.label), context.temp_allocator)
	delete(m.label)
	m.label = label
	return m
}

// --- Selection across edits ---------------------------------------------------------

_sel_snap_clear :: proc(av: ^_Anim_View) {
	context.allocator = runtime.default_allocator()
	for snap in av.sel_snap do delete(snap.chan)
	clear(&av.sel_snap)
	av.sel_primary = -1
}

// The selection as stable keys, when it changed since the last snapshot.
// `clip` is the clip the indices name.
_pv_sel_snapshot :: proc(clip: ^anim.AnimationClip) {
	if !_av.sel_dirty do return
	_av.sel_dirty = false
	context.allocator = runtime.default_allocator()
	if _av.sel_snap.allocator.procedure == nil do _av.sel_snap = make([dynamic]_Sel_Snap)
	_sel_snap_clear(_av)
	for r in _av.sel {
		if r.ch < 0 || r.ch >= len(clip.channels) do continue
		c := &clip.channels[r.ch]
		append(&_av.sel_snap, _Sel_Snap{chan = sheet_channel_key(c), lanes = anim.Lane_Set(c.lanes_off), key = r.key})
		if r.ch == _av.sel_ch && r.key == _av.sel_key do _av.sel_primary = len(_av.sel_snap) - 1
	}
}

// The selection from its stable keys against `clip` as it is now: a key
// whose channel (by stable key, the same lane set when there is one) and
// key index exist is selected again, the others are dropped. The primary
// follows, or the first key.
_pv_sel_restore :: proc(clip: ^anim.AnimationClip) {
	if _av.sel.allocator.procedure == nil do _av.sel.allocator = runtime.default_allocator()
	clear(&_av.sel)
	_av.sel_ch = -1
	_av.sel_key = -1
	for snap, i in _av.sel_snap {
		ch := _sel_find_channel(clip, snap.chan, snap.lanes)
		if ch < 0 || snap.key < 0 || snap.key >= len(clip.channels[ch].times) do continue
		append(&_av.sel, _Key_Ref{ch, snap.key})
		if i == _av.sel_primary || _av.sel_ch < 0 {
			_av.sel_ch = ch
			_av.sel_key = snap.key
		}
	}
	// The indices are the snapshot's again, except the dropped keys.
	_av.sel_dirty = len(_av.sel) != len(_av.sel_snap)
	if _av.sel_dirty do _pv_sel_snapshot(clip)
}

// The channel with stable key `chan` and lane set `lanes`, else the first
// with the key (a split or joined row keeps its selection), else -1.
@(private = "file")
_sel_find_channel :: proc(clip: ^anim.AnimationClip, chan: string, lanes: anim.Lane_Set) -> int {
	first := -1
	for &c, i in clip.channels {
		if sheet_channel_key(&c, context.temp_allocator) != chan do continue
		if anim.Lane_Set(c.lanes_off) == lanes do return i
		if first < 0 do first = i
	}
	return first
}
