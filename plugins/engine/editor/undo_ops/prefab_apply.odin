package undo_ops

// A Prefab Apply as an undo command: the prefab files it wrote with their
// bytes before and after, and the instance's override records before and after.

import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import engine "moonhug:packages/engine"
import core "moonhug:host/core"
import "moonhug:host/log"

// A Prefab Apply (scene_undo.apply_to_prefab): prefab files changed on disk,
// and the instance's records lost what went into them. Undo writes the old
// bytes back and restores the old records, redo the new ones. Either way every
// instance of each prefab then re-resolves (engine.prefab_propagate), so
// instances in other loaded scenes follow the files too.
@(undo_command)
Prefab_Apply_Command :: struct {
	scene:         core.Scene_Ref,
	host_local_id: engine.Local_ID,
	files:         []engine.Applied_File,  // owned
	before:        engine.Nested_Records,  // owned
	after:         engine.Nested_Records,  // owned
}

apply_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command) {
	_prefab_apply_set(v^, true)
}

revert_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command) {
	_prefab_apply_set(v^, false)
}

destroy_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command) {
	engine.applied_files_destroy(v.files)
	delete(v.files)
	engine.nested_records_destroy(&v.before)
	engine.nested_records_destroy(&v.after)
}

label_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command) -> string {
	return "Apply Overrides"
}

scenes_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

assets_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command, out: ^[dynamic]core.Asset_GUID) {
	for f in v.files do append(out, f.guid)
}

describe_Prefab_Apply_Command :: proc(v: ^Prefab_Apply_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%sOverrides applied to %d prefab file(s), instance lid %v\n",
		_indent(depth), len(v.files), v.host_local_id)
}

// The NestedScene of the instance hosted by `host_lid` in scene `r`, found
// again by id because an apply re-resolves the instance.
prefab_apply_ns :: proc(r: core.Scene_Ref, host_lid: engine.Local_ID) -> ^engine.NestedScene {
	sc := _scene(r)
	if sc == nil do return nil
	h, ok := engine.bimap_get(&sc.local_ids, host_lid)
	if !ok || h.type_key != .Transform do return nil
	return engine.scene_find_nested_scene_for_host(sc, engine.Transform_Handle(h))
}

// Puts one side of a Prefab Apply in place: `after` for redo, the state from
// before for undo.
@(private)
_prefab_apply_set :: proc(v: Prefab_Apply_Command, after: bool) {
	// A file that changed on disk since the step (edited outside the editor)
	// is not overwritten: that would lose the change. The step does nothing.
	for f in v.files {
		path, ok := engine.asset_db_get_path(uuid.Identifier(f.guid))
		cur, err := os.read_entire_file(path, context.temp_allocator)
		expect := after ? f.before : f.after
		if !ok || err != nil || string(cur) != string(expect) {
			log.error(fmt.tprintf("undo: %s changed on disk since the Apply, left as it is", path))
			return
		}
	}
	for f in v.files {
		if !engine.prefab_file_write(f.guid, after ? f.after : f.before) {
			log.error(fmt.tprintf("undo: could not write prefab %v", f.guid))
			return
		}
	}
	if ns := prefab_apply_ns(v.scene, v.host_local_id); ns != nil {
		engine.nested_records_restore(ns, after ? v.after : v.before)
	}
	for f in v.files do engine.prefab_propagate(f.guid)
}
