package plugin_example

// The two serialization hooks on an asset type of this package
// (moonhug/libs/serialization): @(after_deserialize) rebuilds what the file
// does not store, @(before_serialize) prepares a value before it is written.
// They run when an asset file is read or written, and on copy and paste in
// the inspector. Scene components do not run them.
//
// The asset is a weighted table of things to spawn: the file holds the
// entries, the loaded value also holds their total weight, which nothing
// saves.

import "core:strings"

@(typ_guid={guid = "1eee5162-8b62-47c7-8273-ab82d1504a39", menu_assets_create = {menu_name = "PluginExample/Spawn Table", file_name = "SpawnTable.asset"}})
Spawn_Table :: struct {
	// The sum of the weights, for spawn_table_pick. Never saved: rebuilt on
	// load and after every edit, shown greyed out in the inspector, with the
	// info box that says what the asset is for.
	total_weight: f32 `json:"-" inspect:"" decor:readonly() decor:help(text="An example asset of the plugin_example plugin, used by no game code. A weighted list of things to spawn: spawn_table_pick picks an entry by weight. It shows the two serialization hooks. The total weight is never saved: the after_deserialize hook rebuilds it when the file loads. Negative weights never reach the file: the before_serialize hook clamps them to 0 right before a save.")`,
	entries:      [dynamic]Spawn_Entry,
}

Spawn_Entry :: struct {
	name:   string,
	weight: f32,
}

// An inspector edit or an undo changes the entries: the total follows.
on_validate_Spawn_Table :: proc(t: ^Spawn_Table) {
	spawn_table_refresh(t)
}

cleanup_Spawn_Table :: proc(t: ^Spawn_Table) {
	for e in t.entries do delete(e.name)
	delete(t.entries)
	t^ = {}
}

// The file has no total weight: it comes back from the entries on load.
@(after_deserialize={type=Spawn_Table})
spawn_table_after_deserialize :: proc(ptr: rawptr, tid: typeid) {
	spawn_table_refresh(cast(^Spawn_Table)ptr)
}

// A negative weight never reaches the file: it is clamped to 0 right before
// the write. The hook runs twice around a write, is_cleanup false before and
// true after, so a hook that changes the value only for the file can put it
// back. This one keeps the clamp.
@(before_serialize={type=Spawn_Table})
spawn_table_before_serialize :: proc(ptr: rawptr, tid: typeid, is_cleanup: bool) {
	if is_cleanup do return
	t := cast(^Spawn_Table)ptr
	for &e in t.entries do e.weight = max(e.weight, 0)
	spawn_table_refresh(t)
}

// Recomputes the total weight from the entries.
spawn_table_refresh :: proc(t: ^Spawn_Table) {
	t.total_weight = 0
	for e in t.entries do t.total_weight += max(e.weight, 0)
}

// The entry a roll in [0, 1) lands on, by weight. Empty when the table has no
// weight.
spawn_table_pick :: proc(t: ^Spawn_Table, roll: f32) -> string {
	if t.total_weight <= 0 do return ""
	at := roll * t.total_weight
	for e in t.entries {
		w := max(e.weight, 0)
		if at < w do return e.name
		at -= w
	}
	return t.entries[len(t.entries) - 1].name
}

// Adds an entry, for code that builds a table.
spawn_table_add :: proc(t: ^Spawn_Table, name: string, weight: f32) {
	append(&t.entries, Spawn_Entry{name = strings.clone(name), weight = weight})
	spawn_table_refresh(t)
}
