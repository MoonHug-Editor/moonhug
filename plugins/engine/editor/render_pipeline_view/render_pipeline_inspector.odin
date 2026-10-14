package render_pipeline_view

// The .renderpipeline asset inspector: the button that opens the pipeline in
// the Render Pipeline window above the document's fields, and the Project
// view's open action.
//
// A .renderpipeline is a typed asset document, which the Project Inspector
// draws through draw_asset_doc and not through an importer's asset funnel, so
// the button goes in through the document hook for Render_Pipeline.

import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(phase={key=EditorInit, order=1, mode=Editor})
render_pipeline_inspector_install :: proc() {
	inspector.add_asset_doc_hook(typeid_of(engine.Render_Pipeline), {before = _render_pipeline_doc_before})
	// A double click or Enter on a .renderpipeline in the Project view opens it.
	asset_pipeline.asset_open_handler_add(".renderpipeline", _open_from_project)
}

@(private = "file")
_open_from_project :: proc(path: string) -> bool {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return false
	render_pipeline_open(path, engine.Asset_GUID(guid))
	return true
}

@(private = "file")
_render_pipeline_doc_before :: proc(doc: ^inspector.Asset_Doc) {
	if im.Button("Open Render Pipeline") do render_pipeline_open(doc.path, doc.guid)
	im.Separator()
}
