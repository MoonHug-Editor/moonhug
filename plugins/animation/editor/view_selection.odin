package animation_editor

// Key selection of the Animation window: the selected keys of the current
// copy (_av.sel), the primary key the footer edits, and the queries the
// sheet, the footer and the drags run over them.

import "base:runtime"
import im "moonhug:external/odin-imgui"
import anim "moonhug:packages/animation"
import wnd "moonhug:editor/window"

// Clears every copy's key selection: the clip they select in changed.
@(private)
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
	_pv_sel_clear()
	_av.drag_key = false
	_av.drag_tan = false
	_av.box = false
}

// --- Key selection ---------------------------------------------------------------------

// The selection is cross-frame state, so it allocates from the default
// allocator whatever the caller's context holds (Record keys under the
// document allocator).
@(private)
_pv_sel_pin :: proc() {
	if _av.sel.allocator.procedure == nil do _av.sel.allocator = runtime.default_allocator()
	if _av.sel_set.allocator.procedure == nil do _av.sel_set.allocator = runtime.default_allocator()
}

// Empties the selection. The primary stays for the caller to set.
@(private)
_pv_sel_clear :: proc() {
	clear(&_av.sel)
	_av.sel_rev += 1
	_av.sel_dirty = true
}

// Appends a key the selection does not hold yet. The set follows the
// append when it is current, so a loop of adds stays linear.
@(private)
_pv_sel_add :: proc(ch, key: int) {
	_pv_sel_pin()
	current := _av.sel_stamp == _pv_sel_stamp()
	append(&_av.sel, _Key_Ref{ch, key})
	_av.sel_dirty = true
	if !current do return
	_av.sel_set[_Key_Ref{ch, key}] = true
	_av.sel_stamp.n = len(_av.sel)
}

// Replace the selection with one key, which becomes primary.
@(private)
_pv_sel_set :: proc(ch, key: int) {
	_pv_sel_clear()
	_pv_sel_add(ch, key)
	_av.sel_ch = ch
	_av.sel_key = key
}

// Add a key to the selection, or drop it when already there (additive click).
// The clicked key becomes primary either way it stays selected.
@(private)
_pv_sel_toggle :: proc(ch, key: int) {
	_av.sel_dirty = true
	for r, i in _av.sel {
		if r.ch == ch && r.key == key {
			ordered_remove(&_av.sel, i)
			_av.sel_rev += 1
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
	_pv_sel_add(ch, key)
	_av.sel_ch = ch
	_av.sel_key = key
}

@(private)
_pv_sel_has :: proc(ch, key: int) -> bool {
	_pv_sel_set_sync()
	return _Key_Ref{ch, key} in _av.sel_set
}

// What the membership set was built from: the selection procs' change count,
// the selection length, and the sheet. A sheet rebuild restores the selection
// from its snapshot (sheet_cache.odin) without going through these procs, so
// a new sheet makes the set stale too.
_Sel_Set_Stamp :: struct {
	rev:      u64,
	n:        int,
	clip:     rawptr,
	doc:      rawptr,
	edits:    u64,
	view_gen: u64,
	nch:      int,
}

@(private = "file")
_pv_sel_stamp :: proc() -> _Sel_Set_Stamp {
	s := &_av.sheet
	return {_av.sel_rev, len(_av.sel), s.clip, s.doc, s.edits, s.view_gen, s.nch}
}

// Rebuilds the membership set when it does not match the selection.
@(private = "file")
_pv_sel_set_sync :: proc() {
	stamp := _pv_sel_stamp()
	if _av.sel_stamp == stamp do return
	_pv_sel_pin()
	clear(&_av.sel_set)
	for r in _av.sel do _av.sel_set[r] = true
	_av.sel_stamp = stamp
}

// Whether every key of `keys` is selected.
@(private)
_pv_sel_has_all :: proc(keys: []Sheet_Key) -> bool {
	for k in keys {
		if !_pv_sel_has(k.ch, k.key) do return false
	}
	return true
}

// Replace the selection with `keys` (an Object row's keys at one time). The
// first becomes primary.
@(private)
_pv_sel_set_keys :: proc(keys: []Sheet_Key) {
	assert(len(keys) > 0, "an Object row summary key stands for at least one key")
	_pv_sel_clear()
	for k in keys do _pv_sel_add(k.ch, k.key)
	_av.sel_ch = keys[0].ch
	_av.sel_key = keys[0].key
}

// Additive click on an Object row summary key: drops its keys when all of them
// are selected, else adds the missing ones. The first of them becomes primary
// when they stay selected.
@(private)
_pv_sel_toggle_keys :: proc(keys: []Sheet_Key) {
	assert(len(keys) > 0, "an Object row summary key stands for at least one key")
	_av.sel_dirty = true
	if _pv_sel_has_all(keys) {
		for k in keys do _pv_sel_toggle(k.ch, k.key)
		return
	}
	for k in keys {
		if !_pv_sel_has(k.ch, k.key) do _pv_sel_add(k.ch, k.key)
	}
	_av.sel_ch = keys[0].ch
	_av.sel_key = keys[0].key
}

// Drop selection entries a document edit has invalidated (a channel or key
// removed by undo, or by deleting keys).
@(private)
_pv_sel_prune :: proc(clip: ^anim.AnimationClip) {
	for i := len(_av.sel) - 1; i >= 0; i -= 1 {
		r := _av.sel[i]
		if r.ch < 0 || r.ch >= len(clip.channels) || r.key < 0 || r.key >= len(clip.channels[r.ch].times) {
			ordered_remove(&_av.sel, i)
			_av.sel_rev += 1
		}
	}
}

// The additive-selection modifier: the platform command key, as elsewhere in
// the editor.
@(private)
_pv_additive :: proc() -> bool {
	io := im.GetIO()
	return io.KeyCtrl || io.KeySuper
}

@(private)
_pv_sel_valid :: proc(clip: ^anim.AnimationClip) -> bool {
	if _av.sel_ch < 0 || _av.sel_ch >= len(clip.channels) do return false
	return _av.sel_key >= 0 && _av.sel_key < len(clip.channels[_av.sel_ch].times)
}

// Which keys of channel `ch_idx` are selected, as a mask parallel to its
// times — the shape animation_key_bounds takes. Temp-allocated per query,
// which only happens while a drag is live.
@(private)
_pv_sel_mask :: proc(ch_idx, count: int) -> []bool {
	mask := make([]bool, count, context.temp_allocator)
	for r in _av.sel {
		if r.ch == ch_idx && r.key >= 0 && r.key < count do mask[r.key] = true
	}
	return mask
}

// A press on key `key` of channel `ch`, the plain (not additive) kind: a key
// already in the selection keeps the selection, so a drag moves all of it,
// an unselected key becomes the whole selection. Either way it becomes the
// primary key.
@(private)
_pv_pick_key :: proc(ch, key: int) {
	if !_pv_sel_has(ch, key) do _pv_sel_set(ch, key)
	_av.sel_ch = ch
	_av.sel_key = key
}

// _pv_pick_key for the keys a summary key stands for: all of them stay
// selected when they already are, else they become the selection. The
// first becomes the primary key.
@(private)
_pv_pick_keys :: proc(keys: []Sheet_Key) {
	if !_pv_sel_has_all(keys) do _pv_sel_set_keys(keys)
	_av.sel_ch = keys[0].ch
	_av.sel_key = keys[0].key
}

