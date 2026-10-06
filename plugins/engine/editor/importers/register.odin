package importers

// The engine's importers (texture, mesh, shader) and the glTF clip hooks the
// animation package fills. Each importer names its own settings type, so the
// shell's registry knows none of them.

import "base:runtime"
import cgltf "vendor:cgltf"
import "core:encoding/json"
import "core:strings"
import "moonhug:packages/engine"
import assets "moonhug:host/assets"
import asset_pipeline "moonhug:editor/assets"

// Bakes one glTF animation of `data` to `out_path`, the model's _a<i>.bin
// fan-out. Installed by the animation package's editor half at
// ImportersInit: the clip format is that package's, and this one stays
// plugin-agnostic. nil = the mesh importer lists clips but bakes none.
Gltf_Clip_Baker :: proc(data: ^cgltf.data, an: ^cgltf.animation, settings: json.Value, out_path: string) -> bool
gltf_clip_baker: Gltf_Clip_Baker

// What the editor's glTF extraction ("Assets/Extract Assets") writes for
// animations. Installed with the baker, by the animation package. nil procs =
// extraction writes no clips.
// - `write`: one glTF animation of `data` as a clip asset at `out_path`.
//   false when the animation has no usable channels or the write failed.
// - `decorate`: puts the component that plays `clip` on `root`, the root of
//   the scene extraction writes.
Gltf_Clip_Extractor :: struct {
	write:    proc(data: ^cgltf.data, an: ^cgltf.animation, out_path: string) -> bool,
	decorate: proc(root: engine.Transform_Handle, clip: engine.Asset_GUID),
}
gltf_clip_extractor: Gltf_Clip_Extractor

_TEXTURE_EXTS := []string{".png", ".jpg", ".jpeg", ".bmp"}
_MESH_EXTS    := []string{".glb", ".gltf"}
_SHADER_EXTS  := []string{".glsl"}

@(phase={key=ImportersInit, order=0, mode=Editor})
register_builtin_importers :: proc() {
	@(static) done := false
	if done do return
	done = true

	assets.asset_db_add_path_changed_hook(_reimport_changed_shader)

	asset_pipeline.importer_register({
		name         = "texture",
		version      = 1,
		extensions   = _TEXTURE_EXTS,
		settings_tid = typeid_of(engine.TextureSettings),
		run          = _import_texture,
	})
	asset_pipeline.importer_register({
		name         = "mesh",
		version      = 4, // 2: artifacts carry skin data. 3: clips baked to the _a<i> fan-out. 4: re-bake the clips the startup sweep deleted
		extensions   = _MESH_EXTS,
		settings_tid = typeid_of(engine.MeshSettings),
		run          = _import_mesh,
		artifacts    = _mesh_artifacts,
		sub_assets   = engine.asset_db_register_model_subs,
	})
	asset_pipeline.importer_register({
		name         = "shader",
		version      = 1,
		extensions   = _SHADER_EXTS,
		settings_tid = typeid_of(engine.ShaderSettings),
		run          = _import_shader,
	})
}

// Shader hot reload: the shader cache's evict hook drops an edited .glsl, this
// path-changed hook reimports it.
@(private = "file")
_reimport_changed_shader :: proc(path: string) {
	if strings.has_suffix(path, ".glsl") {
		_ = asset_pipeline.asset_pipeline_import_asset(path)
	}
}

@(private = "file")
_mesh_artifacts :: proc(artifact_path: string, allocator: runtime.Allocator) -> []string {
	return engine.mesh_artifacts(artifact_path, allocator)
}
