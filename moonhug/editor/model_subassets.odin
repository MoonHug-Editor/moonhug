package editor

// The Project Inspector section a selected clip inside a model gets, and the
// rig the clip preview and clip thumbnails pose. The clip rows themselves come
// from the model provider in engine_editor/mesh_editor, which lists parts and
// clips. A clip row drags as (model guid, clip id), which a clip field turns
// back into the clip's own guid (property_drawer_asset_guid.odin), so a clip is
// assigned straight from the model without extracting anything.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import cgltf "vendor:cgltf"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import anim "moonhug:packages/animation"
import "inspector"
import "moonhug:editor/widgets"

_register_model_clip_ui :: proc() {
	inspector.add_asset_wrapper("mesh", _model_clip_section)
}

// --- The selected clip's section in the Project Inspector -----------------------
//
// Selecting a clip under a model selects the model with that sub id, so the
// model's import settings show. This wrapper adds, below them, the one clip's
// own settings — or, for a clip the model no longer has, a remap. Edits land in
// the model's working-copy settings (engine.Mesh_Clip.settings), and the Apply
// button above saves the meta and reimports, which is when the bake picks
// them up. Settings live in the meta, never in the artifact, the same rule a
// standalone .anim follows.

// Typed working copy of the selected clip's settings: the reflected drawer
// edits a struct, the meta holds a JSON value. Re-materialised when the
// selection moves to another clip.
@(private = "file") _clip_edit: struct {
	path:  string, // owned
	id:    engine.Local_ID,
	s:     anim.Animation_Clip_Settings,
	valid: bool,
}

@(private = "file")
_clip_edit_load :: proc(path: string, clip: ^engine.Mesh_Clip) {
	context.allocator = runtime.default_allocator()
	delete(_clip_edit.path)
	_clip_edit.path = strings.clone(path)
	_clip_edit.id = clip.id
	_clip_edit.s = anim.Animation_Clip_Settings{frame_rate = anim.ANIMATION_FRAME_RATE_DEFAULT}
	if clip.settings != nil {
		engine._settings_overlay(any{&_clip_edit.s, typeid_of(anim.Animation_Clip_Settings)}, clip.settings)
	}
	_clip_edit.valid = true
}

// Writes the typed copy back into the meta entry as a JSON value, on the
// default allocator the working-copy settings live on.
@(private = "file")
_clip_edit_store :: proc(clip: ^engine.Mesh_Clip) {
	context.allocator = runtime.default_allocator()
	bytes, merr := json.marshal(_clip_edit.s, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return
	v, perr := json.parse(bytes, .JSON, true)
	if perr != nil do return
	if clip.settings != nil do json.destroy_value(clip.settings)
	clip.settings = v
}

@(private = "file")
_model_clip_section :: proc(ctx: ^inspector.Asset_Ctx) {
	inspector.draw(ctx) // Apply + the reflected MeshSettings

	if ctx.settings.id != typeid_of(engine.MeshSettings) do return
	ms := cast(^engine.MeshSettings)ctx.settings.data
	sub, has_sub := _preview_selected_sub(ctx.path)
	if !has_sub do return
	idx := -1
	for c, i in ms.clips do if c.id == sub.id { idx = i; break }
	if idx < 0 do return // a mesh part
	clip := &ms.clips[idx]

	im.Separator()
	im.SeparatorText(strings.clone_to_cstring(fmt.tprintf("Clip: %s", clip.name), context.temp_allocator))

	if clip.orphan {
		im.TextDisabled("Not in the model any more. Remap it and every reference follows.")
		if im.BeginCombo("Remap to", "choose a clip") {
			for &c in ms.clips {
				if c.orphan do continue
				if im.Selectable(strings.clone_to_cstring(c.name, context.temp_allocator)) {
					// The orphan's guid is the one scenes hold, so it moves to
					// the chosen clip. That clip's own guid, minted at import
					// and referenced by nothing yet, goes.
					c.guid = clip.guid
					if c.settings == nil {
						c.settings = clip.settings
						clip.settings = nil
					}
					context.allocator = runtime.default_allocator()
					if clip.settings != nil do json.destroy_value(clip.settings)
					ordered_remove(&ms.clips, idx)
					inspector.mark_inspector_changed()
					_clip_edit.valid = false
					im.EndCombo()
					return
				}
			}
			im.EndCombo()
		}
		widgets.tooltip("Apply above to bake. The chosen clip takes this entry's guid.")
		return
	}

	if !_clip_edit.valid || _clip_edit.path != ctx.path || _clip_edit.id != clip.id {
		_clip_edit_load(ctx.path, clip)
	}
	// The drawer sets the shared changed flag. Read it around this draw only,
	// and put the caller's own state back afterwards.
	outer := inspector.consume_inspector_changed()
	inspector.draw_inspector(any{&_clip_edit.s, typeid_of(anim.Animation_Clip_Settings)})
	if inspector.consume_inspector_changed() {
		_clip_edit_store(clip)
		outer = true
	}
	if outer do inspector.mark_inspector_changed()
	im.TextDisabled("Apply above to bake the clip with these settings.")
}

// --- The rig a clip is previewed on -------------------------------------------

// The model's node hierarchy as live transforms under `parent` (the preview
// world's root), and a one-clip graph that poses it. The glTF is parsed
// without its buffers, since geometry comes from the model's artifact through
// the MeshFilter each node gets. Materials stay empty, the default draws.
Model_Clip_Rig :: struct {
	root:  engine.Transform_Handle,
	graph: anim.Playable_Graph,
	node:  anim.Playable_Handle,
	clip:  engine.Asset_GUID,
	length: f32,
}

model_clip_rig_build :: proc(path: string, owner: engine.Asset_GUID, clip_id: engine.Local_ID, parent: engine.Transform_Handle) -> (rig: Model_Clip_Rig, ok: bool) {
	clip_guid, cok := engine.asset_db_sub_guid(owner, clip_id)
	if !cok do return
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	data, res := cgltf.parse_file(cgltf.options{}, path_c)
	if res != .success do return
	defer cgltf.free(data)

	rig.root = engine.transform_new(filepath.stem(path), parent)
	engine.scene_gltf_populate(data, rig.root, owner, nil)
	rig.clip = clip_guid
	rig.length = 1
	if clip, lok := anim.animation_clip_load(clip_guid); lok && clip.length > 0 do rig.length = clip.length

	anim.playable_graph_init(&rig.graph)
	out := anim.graph_output_add(&rig.graph, rig.root)
	rig.node = anim.playable_add(&rig.graph, anim.Playable_Clip{clip = clip_guid})
	rig.graph.outputs[out].root = rig.node
	return rig, true
}

// Poses the rig at `t` seconds. Must run inside the preview world it was built in.
model_clip_rig_pose :: proc(rig: ^Model_Clip_Rig, t: f32) {
	if n := anim.playable_node(&rig.graph, rig.node); n != nil do n.time = t
	anim.playable_graph_tick(&rig.graph)
}

model_clip_rig_destroy :: proc(rig: ^Model_Clip_Rig) {
	if rig.root != {} do engine.transform_destroy(rig.root)
	anim.playable_graph_destroy(&rig.graph)
	rig^ = {}
}
