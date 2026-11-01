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
	clear(&_av.sel)
	_av.sel_dirty = true
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
}

// Replace the selection with one key, which becomes primary.
@(private)
_pv_sel_set :: proc(ch, key: int) {
	_pv_sel_pin()
	clear(&_av.sel)
	append(&_av.sel, _Key_Ref{ch, key})
	_av.sel_ch = ch
	_av.sel_key = key
	_av.sel_dirty = true
}

// Add a key to the selection, or drop it when already there (additive click).
// The clicked key becomes primary either way it stays selected.
@(private)
_pv_sel_toggle :: proc(ch, key: int) {
	_av.sel_dirty = true
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

@(private)
_pv_sel_has :: proc(ch, key: int) -> bool {
	for r in _av.sel {
		if r.ch == ch && r.key == key do return true
	}
	return false
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
	_pv_sel_pin()
	_av.sel_dirty = true
	clear(&_av.sel)
	for k in keys do append(&_av.sel, _Key_Ref{k.ch, k.key})
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
	_pv_sel_pin()
	for k in keys {
		if !_pv_sel_has(k.ch, k.key) do append(&_av.sel, _Key_Ref{k.ch, k.key})
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
