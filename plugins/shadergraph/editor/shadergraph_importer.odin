package shadergraph_editor

// The .shadergraph importer: codegen, then the same compile the .glsl
// importer runs, into the same shader artifact. A Material's custom_shader
// then loads a graph exactly as it loads a .glsl (engine.shader_load reads
// the artifact by guid, whatever the source was).
//
// Editing the graph reimports it: the evict hook drops the cached shader
// and asks the pipeline for a new artifact, the way a .glsl edit does.

import "core:strings"
import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine/editor/importers"
import "moonhug:libs/log"
import sg "moonhug:packages/shadergraph"

@(phase={key=ImportersInit, order=2, mode=Editor})
shadergraph_importers_init :: proc() {
	@(static) done := false
	if done do return
	done = true
	asset_pipeline.importer_register({
		name         = "shadergraph",
		version      = importers.shader_importer_version(), // the template is an input here too
		extensions   = {".shadergraph"},
		settings_tid = typeid_of(engine.ShaderSettings),
		run          = _import_shadergraph,
	})
	engine.asset_db_add_evict_hook(_shadergraph_path_changed)
}

@(private = "file")
_import_shadergraph :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	g, ok := sg.graph_load_file(source_path)
	if !ok {
		log.errorf("[Pipeline] %s is not a shader graph", source_path)
		return false
	}
	defer sg.cleanup_Shader_Graph(&g)
	result, gen_ok := sg.generate(&g)
	if !gen_ok {
		for e in result.errors do log.errorf("[Pipeline] %s: node %d: %s", source_path, e.node_id, e.message)
		return false
	}
	return importers.shader_compile_source(result.glsl, source_path, artifact_path)
}

// A changed or deleted graph: drop its shader and reimport, so the next
// draw with a material on it picks up the new artifact.
@(private = "file")
_shadergraph_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".shadergraph") do return
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return
	engine.shader_unload(engine.Asset_GUID(guid))
	_ = asset_pipeline.asset_pipeline_import_asset(path)
}
