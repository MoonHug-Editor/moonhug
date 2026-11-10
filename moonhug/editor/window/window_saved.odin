package window

// Saved window state (docs/core/Windows.md, "Saved state").
//
// A window that asks for its state with state(w, init, saved = true) has it
// saved by the registry, under the instance's key:
//
//   - The state struct goes through the json marshaller as it is. A field
//     that must not be saved carries `json:"-"`, as a component's does.
//   - The saved fields are kept as JSON text per key (a record). A new
//     instance's state starts as `init` with its key's record read over it.
//   - A closing instance's record is taken before its closed proc runs. The
//     struct itself is kept while the instance can come back under its key
//     (can_reopen), so a reopened instance has every field as it was, the
//     unsaved ones too. A closed proc that frees the struct sets w.data to
//     nil, and the instance then comes back from its record alone.
//   - A record goes when its instance is not open and cannot come back. The
//     plain instance's record (key = the window's id) stays: opening the
//     window again shows it as it was left.
//
// The registry writes no file. The editor saves the records with the user
// settings, and a workspace saves those of its frames' windows (saved_keys,
// saved_text, saved_set).

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import core "moonhug:libs/core"

@(private = "file")
_Record :: struct {
	raw:  string, // the state as the marshaller wrote it last, owned
	text: string, // the same with sorted keys, owned: equal states give equal text
}

@(private = "file")
_Parked :: struct {
	data: rawptr,
	type: typeid,
}

// By instance key, owned keys. On the default allocator: they outlive frames.
@(private = "file")
_records: map[string]_Record
@(private = "file")
_parked: map[string]_Parked

// Marks the new state of `w` as saved, and gives its key's record for
// state() to read over it, "" for none.
@(private)
_saved_begin :: proc(w: ^Window, type: typeid) -> string {
	w.saved = type
	return _records[w.key].text
}

// Takes the record of an open instance from its state as it is now.
@(private = "file")
_capture :: proc(w: ^Window) {
	if w.saved == nil || w.data == nil do return
	raw, err := json.marshal(any{w.data, w.saved}, {spec = .JSON}, context.temp_allocator)
	if err != nil do return
	if rec, has := _records[w.key]; has && rec.raw == string(raw) do return
	_record_set(w.key, string(raw))
}

@(private = "file")
_record_set :: proc(key: string, raw: string) {
	context.allocator = runtime.default_allocator()
	value, perr := json.parse_string(raw, .JSON, true, context.temp_allocator)
	if perr != nil do return
	sorted, merr := json.marshal(value, {spec = .JSON, sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil do return
	text := core.json_canonicalize_floats(sorted, context.temp_allocator)
	rec := _Record{raw = strings.clone(raw), text = strings.clone(string(text))}
	if old, has := _records[key]; has {
		delete(old.raw)
		delete(old.text)
		_records[key] = rec
	} else {
		_records[strings.clone(key)] = rec
	}
}

@(private = "file")
_record_drop :: proc(key: string) {
	if key not_in _records do return
	k, rec := delete_key(&_records, key)
	delete(rec.raw, runtime.default_allocator())
	delete(rec.text, runtime.default_allocator())
	delete(k, runtime.default_allocator())
}

// The saved state of the instance `key` as JSON text with sorted keys, ""
// for none: an open instance's as it is now, a closed one's as it was left.
// Borrowed until the next call for the key.
saved_text :: proc(key: string) -> string {
	if w := find(key); w != nil do _capture(w)
	return _records[key].text
}

// Gives the instance `key` the saved state `text` (JSON), for the next
// instance that opens under the key. An open instance keeps its own.
saved_set :: proc(key: string, text: string) {
	if text == "" || find(key) != nil do return
	_record_set(key, text)
}

// Whether a saved state is kept for the instance `key`.
saved_has :: proc(key: string) -> bool {
	return key in _records
}

// The keys that have a saved state, open instances as they are now.
saved_keys :: proc(allocator := context.temp_allocator) -> []string {
	for w in _windows do if w.open do _capture(w)
	out := make([dynamic]string, 0, len(_records), allocator)
	for key in _records do append(&out, key)
	return out[:]
}

// A closing instance: its record is taken, before its closed proc runs.
@(private)
_saved_closing :: proc(w: ^Window) {
	_capture(w)
}

// A closed instance's state struct, after its closed proc: kept for the
// instance that opens under the key next.
@(private)
_saved_park :: proc(w: ^Window) {
	if w.saved == nil || w.data == nil do return
	context.allocator = runtime.default_allocator()
	if old, has := _parked[w.key]; has {
		free(old.data)
		_parked[w.key] = _Parked{w.data, w.saved}
	} else {
		_parked[strings.clone(w.key)] = _Parked{w.data, w.saved}
	}
	w.data = nil
}

// A new instance takes the state struct its key's last instance left.
@(private)
_saved_unpark :: proc(w: ^Window) {
	if w.key not_in _parked do return
	k, p := delete_key(&_parked, w.key)
	delete(k, runtime.default_allocator())
	w.data = p.data
	w.saved = p.type
}

// After instances closed: what cannot come back under its key goes. A plain
// instance's record stays.
@(private)
_saved_prune :: proc() {
	gone := make([dynamic]string, context.temp_allocator)
	for key in _parked do if find(key) == nil && !can_reopen(key) do append(&gone, key)
	for key in gone {
		k, p := delete_key(&_parked, key)
		free(p.data, runtime.default_allocator())
		delete(k, runtime.default_allocator())
	}
	clear(&gone)
	for key in _records {
		if strings.index_byte(key, '/') < 0 do continue
		if find(key) == nil && !can_reopen(key) do append(&gone, key)
	}
	for key in gone do _record_drop(key)
}

@(private)
_saved_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for key, p in _parked {
		free(p.data)
		delete(key)
	}
	delete(_parked)
	_parked = nil
	for key, rec in _records {
		delete(rec.raw)
		delete(rec.text)
		delete(key)
	}
	delete(_records)
	_records = nil
}
