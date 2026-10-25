package shadergraph_tests

// A .shadergraph as the shared asset document the Shader Graph window edits:
// it loads with its own type, and a save writes the Shader_Graph type tag and
// the edit.

import "core:encoding/uuid"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import sg "moonhug:packages/shadergraph"
import common "moonhug:tests/common"

@(private = "file")
_DIR :: "moonhug/tests/fixtures/_shadergraph_doc_tmp"

@(test)
shadergraph_saves_as_a_shared_document :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)
	os.make_directory(_DIR)
	defer {
		common.remove_tree(_DIR)
		common.remove_tree(engine.library_dir())
	}

	path :: _DIR + "/Rim.shadergraph"
	g := _rim_graph()
	defer sg.cleanup_Shader_Graph(&g)
	testing.expect(t, sg.graph_save_file(&g, path), "the graph file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(_DIR)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()

	doc := inspector.asset_doc_get(path)
	testing.expect(t, doc != nil && doc.data.id == typeid_of(sg.Shader_Graph), "the file loads as a Shader_Graph document")
	if doc == nil do return
	// An edit allocates into the document, so it uses the document allocator,
	// as the Shader Graph window does.
	graph := (^sg.Shader_Graph)(doc.data.data)
	{
		context.allocator = inspector.doc_alloc()
		sg.graph_add_property(graph, "extra", .Float, {1, 0, 0, 0})
	}
	doc.dirty = true

	testing.expect(t, inspector.asset_doc_save(doc), "the document saves")
	data, err := os.read_entire_file(path, context.temp_allocator)
	type_guid := uuid.to_string(engine.get_guid_by_typeid(sg.Shader_Graph), context.temp_allocator)
	testing.expect(t, err == nil && strings.contains(string(data), type_guid), "the file carries the Shader_Graph type tag")
	loaded, ok := sg.graph_load_file(path)
	defer sg.cleanup_Shader_Graph(&loaded)
	testing.expect(t, ok && len(loaded.properties) == 3, "the saved graph has the added property")
}
