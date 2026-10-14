package shadergraph_editor

// The .shadergraph asset inspector: the importer settings, then the button
// that opens the graph in the Shader Graph window.

import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(phase={key=EditorInit, order=1, mode=Editor})
shadergraph_inspector_install :: proc() {
	inspector.add_asset_wrapper("shadergraph", _shadergraph_inspector)
	// A double click or Enter on a .shadergraph in the Project view opens it.
	asset_pipeline.asset_open_handler_add(".shadergraph", _open_from_project)
}

@(private = "file")
_open_from_project :: proc(path: string) -> bool {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return false
	shader_graph_open(path, engine.Asset_GUID(guid))
	return true
}

@(private = "file")
_shadergraph_inspector :: proc(ctx: ^inspector.Asset_Ctx) {
	inspector.draw(ctx)
	im.Separator()
	if im.Button("Open Shader Graph") do shader_graph_open(ctx.path, ctx.guid)
}
