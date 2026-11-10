package scene_undo

// A scene's sub-asset created, renamed or removed, each as one undo step
// (undo_ops.Scene_Sub_Asset_Command). The editor changes a scene's
// sub-assets through these, not through the engine's procs.

import shell "moonhug:editor/undo"
import engine "moonhug:packages/engine"
import "moonhug:packages/engine/editor/undo_ops"

// Adds a sub-asset of `type` to the scene: its data as JSON text.
sub_asset_create :: proc(s: ^engine.Scene, type, name, data_json: string) -> (ref: engine.PPtr, ok: bool) {
	ref = engine.scene_sub_asset_add(s, type, data_json, name) or_return
	s.dirty = true
	_sub_asset_record(s, ref.local_id, "Create Sub-Asset", {}, len(s.assets) - 1)
	return ref, true
}

sub_asset_rename :: proc(s: ^engine.Scene, local_id: engine.Local_ID, name: string) -> bool {
	before, index := undo_ops.scene_sub_asset_state(s, local_id)
	if !before.present do return false
	if before.name == name || !engine.scene_sub_asset_rename(s, local_id, name) {
		undo_ops.scene_sub_asset_state_destroy(&before)
		return false
	}
	s.dirty = true
	_sub_asset_record(s, local_id, "Rename Sub-Asset", before, index)
	return true
}

// Removes the sub-asset. A field that points at it keeps its reference and
// shows it as missing, and undo brings the sub-asset back under the same id.
sub_asset_remove :: proc(s: ^engine.Scene, local_id: engine.Local_ID) -> bool {
	before, index := undo_ops.scene_sub_asset_state(s, local_id)
	if !before.present do return false
	engine.scene_sub_asset_remove(s, local_id)
	engine.texture_unload(engine.asset_key(engine.PPtr{guid = s.asset_guid, local_id = local_id}))
	s.dirty = true
	_sub_asset_record(s, local_id, "Delete Sub-Asset", before, index)
	return true
}

// Pushes the step: `before` is the record as it was (taken over), the
// record as it is now is read here.
@(private = "file")
_sub_asset_record :: proc(s: ^engine.Scene, local_id: engine.Local_ID, label: string, before: undo_ops.Scene_Sub_Asset_State, index: int) {
	before := before
	stack := shell.get()
	if stack == nil || !stack.recording || stack.applying {
		undo_ops.scene_sub_asset_state_destroy(&before)
		return
	}
	after, _ := undo_ops.scene_sub_asset_state(s, local_id)
	cmd := undo_ops.Scene_Sub_Asset_Command{
		scene    = scene_ref(s),
		local_id = local_id,
		index    = index,
		label    = label,
		before   = before,
		after    = after,
	}
	shell.push(stack, shell.Command(cmd))
}
