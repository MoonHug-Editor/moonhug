package shadergraph_editor

// The .shadergraph asset inspector: the importer settings, then the button
// that opens the graph in the Shader Graph window.

import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"
@(require) import sg "moonhug:packages/shadergraph" // names the settings type the inspector step is keyed by

@(phase={key=EditorInit, order=1, mode=Editor})
shadergraph_inspector_install :: proc() {
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

@(property_drawer={type=sg.Shader_Graph_Settings, order="middle"})
property_drawer_Shader_Graph_Settings_inspector :: proc(ctx: ^inspector.Ctx) {
	inspector.draw(ctx)
	im.Separator()
	if im.Button("Open Shader Graph") do shader_graph_open(ctx.asset.path, ctx.asset.guid)
}
