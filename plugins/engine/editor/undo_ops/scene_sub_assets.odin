package undo_ops

// The undo command of a scene's sub-assets (plugins/engine/scene_sub_assets.odin):
// one command for a sub-asset created, renamed or removed. It keeps the
// record as it was before and as it is after, and each direction puts one of
// the two back. A change to a sub-asset's data is not this command: the
// inspector edits it as a document, and its rows record value edits.

import "core:fmt"
import "core:strings"
import engine "moonhug:packages/engine"
import core "moonhug:libs/core"

// A sub-asset's record at one moment. `present` false: the scene has none
// under the id. The strings are the command's own.
Scene_Sub_Asset_State :: struct {
	present: bool,
	type:    string,
	name:    string,
	data:    string, // JSON text
}

@(undo_command)
Scene_Sub_Asset_Command :: struct {
	scene:    core.Scene_Ref,
	local_id: engine.Local_ID,
	// Where the record is in the scene's list, for one put back.
	index:    int,
	label:    string, // a literal
	before:   Scene_Sub_Asset_State,
	after:    Scene_Sub_Asset_State,
}

// The scene's sub-asset `local_id` as it is now, the strings on context.allocator.
scene_sub_asset_state :: proc(s: ^engine.Scene, local_id: engine.Local_ID) -> (state: Scene_Sub_Asset_State, index: int) {
	type, name, data, at, ok := engine.scene_sub_asset_get(s, local_id, context.allocator)
	if !ok do return {}, len(s.assets)
	return {present = true, type = type, name = name, data = data}, at
}

scene_sub_asset_state_destroy :: proc(state: ^Scene_Sub_Asset_State) {
	delete(state.type)
	delete(state.name)
	delete(state.data)
	state^ = {}
}

apply_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command) {
	_scene_sub_asset_put(v, v.after)
}

revert_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command) {
	_scene_sub_asset_put(v, v.before)
}

@(private = "file")
_scene_sub_asset_put :: proc(v: ^Scene_Sub_Asset_Command, state: Scene_Sub_Asset_State) {
	s := _scene(v.scene)
	if s == nil do return
	if !state.present {
		engine.scene_sub_asset_remove(s, v.local_id)
		return
	}
	engine.scene_sub_asset_put(s, v.local_id, state.type, state.name, state.data, v.index)
}

destroy_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command) {
	scene_sub_asset_state_destroy(&v.before)
	scene_sub_asset_state_destroy(&v.after)
}

label_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command) -> string {
	return v.label
}

scenes_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command, out: ^[dynamic]core.Scene_Ref) {
	append(out, v.scene)
}

describe_Scene_Sub_Asset_Command :: proc(v: ^Scene_Sub_Asset_Command, b: ^strings.Builder, depth: int) {
	fmt.sbprintf(b, "%s%s: sub-asset %d\n", _indent(depth), v.label, i64(v.local_id))
	if v.before.present do fmt.sbprintf(b, "%s  before: %s %q\n", _indent(depth), v.before.type, v.before.name)
	if v.after.present do fmt.sbprintf(b, "%s  after: %s %q\n", _indent(depth), v.after.type, v.after.name)
}
