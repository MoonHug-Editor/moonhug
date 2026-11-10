package window_render_pipeline

// The .renderpipeline asset inspector: the button that opens the pipeline in
// the Render Pipeline window above the document's fields, and the Project
// window's open action.
//
// A .renderpipeline is a typed asset document, which the Project Inspector
// draws through draw_asset_doc, so the button is a step on Render_Pipeline.

import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"

@(phase={key=EditorInit, order=1, mode=Editor})
render_pipeline_inspector_install :: proc() {
	// A double click or Enter on a .renderpipeline in the Project window opens it.
	asset_pipeline.asset_open_handler_add(".renderpipeline", _open_from_project)
}

@(private = "file")
_open_from_project :: proc(path: string) -> bool {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return false
	render_pipeline_open(path, engine.Asset_GUID(guid))
	return true
}

// An Open button above the pipeline's fields, for the document being drawn.
@(property_drawer={type=engine.Render_Pipeline, order="middle"})
property_drawer_Render_Pipeline_open :: proc(ctx: ^inspector.Ctx) {
	if doc := inspector.asset_doc_of(ctx.ptr); doc != nil {
		if im.Button("Open Render Pipeline") do render_pipeline_open(doc.path, doc.ref.guid)
		im.Separator()
	}
	inspector.draw(ctx)
}
