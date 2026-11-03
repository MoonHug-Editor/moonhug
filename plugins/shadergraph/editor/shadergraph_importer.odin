package shadergraph_editor

// The .shadergraph importer: codegen, then the same compile the .glsl
// importer runs, into the same shader artifact. A Material's custom_shader
// then loads a graph exactly as it loads a .glsl (engine.shader_load reads
// the artifact by guid, whatever the source was).
//
// Editing the graph reimports it: its asset hook drops the cached shader
// and asks the pipeline for a new artifact, the way a .glsl edit does.

import "moonhug:packages/engine"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine/editor/importers"
import "moonhug:libs/log"
import sg "moonhug:packages/shadergraph"

_SHADERGRAPH_EXTS := []string{".shadergraph"}

@(importer)
shadergraph_importer :: proc() -> asset_pipeline.Importer_Desc {
	return {
		name         = "shadergraph",
		version      = importers.shader_importer_version(), // the template is an input here too
		extensions   = _SHADERGRAPH_EXTS,
		settings_tid = typeid_of(sg.Shader_Graph_Settings),
		run          = _import_shadergraph,
	}
}

@(private = "file")
_import_shadergraph :: proc(source_path: string, artifact_path: string, settings: rawptr) -> bool {
	g, ok := sg.graph_load_file(source_path)
	if !ok {
		log.errorf("[Pipeline] %s is not a shader graph", source_path)
		return false
	}
	defer sg.type_cleanup_Shader_Graph(&g)
	result, gen_ok := sg.generate(&g)
	if !gen_ok {
		for e in result.errors do log.errorf("[Pipeline] %s: node %d: %s", source_path, e.node_id, e.message)
		return false
	}
	return importers.shader_compile_source(result.glsl, source_path, artifact_path)
}

// A changed or deleted graph: drop its shader and reimport, so the next
// draw with a material on it picks up the new artifact.
@(asset_on_changed={ext="shadergraph"})
asset_on_changed_shadergraph :: proc(guid: engine.Asset_GUID, path: string, change: engine.Asset_Change) {
	if change == .Reimported do return
	engine.shader_unload(guid)
	if change == .Modified do _ = asset_pipeline.asset_pipeline_import_asset(path)
}
