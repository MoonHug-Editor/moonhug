package editor

// The rig the clip preview and clip thumbnails pose: a clip inside a model,
// shown on the model's own node hierarchy. The clip rows come from the model
// provider in engine_editor/mesh_editor, which lists parts and clips. The
// animation package poses the rig (subassets.clip_sampler) and draws the
// selected clip's settings in the Project Inspector.

import "core:path/filepath"
import "core:strings"
import cgltf "vendor:cgltf"
import "moonhug:engine"
import "subassets"

// The model's node hierarchy as live transforms under `parent` (the preview
// world's root), posed by one clip. The glTF is parsed without its buffers,
// since geometry comes from the model's artifact through the MeshFilter each
// node gets. Materials stay empty, the default draws.
Model_Clip_Rig :: struct {
	root:   engine.Transform_Handle,
	clip:   engine.Asset_GUID,
	length: f32,
}

// ok=false without a clip sampler (no animation package installed).
model_clip_rig_build :: proc(path: string, owner: engine.Asset_GUID, clip_id: engine.Local_ID, parent: engine.Transform_Handle) -> (rig: Model_Clip_Rig, ok: bool) {
	if subassets.clip_sampler == nil do return
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
	if length, sok := subassets.clip_sampler(rig.root, clip_guid, 0); sok && length > 0 do rig.length = length
	return rig, true
}

// Poses the rig at `t` seconds. Must run inside the preview world it was built in.
model_clip_rig_pose :: proc(rig: ^Model_Clip_Rig, t: f32) {
	_, _ = subassets.clip_sampler(rig.root, rig.clip, t)
}

model_clip_rig_destroy :: proc(rig: ^Model_Clip_Rig) {
	if rig.root != {} do engine.transform_destroy(rig.root)
	rig^ = {}
}
