package editor

// The bridge's asset document tools (docs/core/McpBridge.md "Assets"): read
// and change an asset the way the Project Inspector does, through its
// document (inspector/asset_docs.odin). An asset is a file the inspector
// edits (.mat, .asset, .noise), or a sub-asset that is a document (one a
// scene file holds), named by its file's path and its local id.

import "core:encoding/json"
import mcp "moonhug:editor/mcp"
import "moonhug:editor/inspector"
import core "moonhug:libs/core"
import ser "moonhug:libs/serialization"

// The document of the asset at `path`, or of the sub-asset `sub_id` of the
// file at `path`.
@(private = "file")
_asset_tool_doc :: proc(params: json.Object) -> (doc: ^inspector.Asset_Doc, err: Mcp_Error) {
	path, _ := params["path"].(json.String)
	if path == "" do return nil, Mcp_Error{"bad_request", "path is required"}
	doc = inspector.asset_doc_get(string(path), core.Local_ID(mcp.json_int(params, "sub_id", 0)))
	if doc == nil do return nil, Mcp_Error{"not_found", "no asset document there: not an asset the inspector edits, or no such sub-asset"}
	return doc, {}
}

@(mcp_tool={
	description="An asset's document as the Project Inspector edits it: its values as JSON, its sub-asset id (0 for a file), and whether it has unsaved edits. For a file asset pass its path. For a sub-asset that is a document (a material a scene file holds) pass the file's path and the sub-asset's local id, as the Project window lists them under the file.",
	param_path="string!:The asset's path, or the path of the file that holds the sub-asset, relative to the project root",
	param_sub_id="integer:The sub-asset's local id (default 0: the file itself)",
})
mcp_tool_asset_document :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	doc, err := _asset_tool_doc(params)
	if err.code != "" do return "", err
	text, ok := ser.save_to_text(doc.data)
	if !ok do return mcp.tool_fail("failed", "the document does not marshal")
	values, perr := json.parse_string(text, .JSON, true, context.temp_allocator)
	if perr != nil do return mcp.tool_fail("failed", "the document's JSON does not parse")
	return mcp.tool_ok(struct {
		sub_id: i64,
		dirty:  bool,
		values: json.Value,
	}{sub_id = i64(doc.ref.local_id), dirty = doc.dirty, values = values})
}

@(mcp_tool={
	description="Changes fields of an asset's document, as an edit in the Project Inspector does: the given fields replace the document's, the rest keep their values, and what uses the asset shows the change at once. A file asset is then unsaved until File/Save. A sub-asset's change goes to the file that holds it, which becomes unsaved. Not an undo step.",
	param_path="string!:The asset's path, or the path of the file that holds the sub-asset, relative to the project root",
	param_sub_id="integer:The sub-asset's local id (default 0: the file itself)",
	param_values="object!:The fields to set, as the asset's JSON names them",
})
mcp_tool_asset_document_set :: proc(id: i64, params: json.Object) -> (string, Mcp_Error) {
	doc, err := _asset_tool_doc(params)
	if err.code != "" do return "", err
	values, is_obj := params["values"].(json.Object)
	if !is_obj do return mcp.tool_fail("bad_request", "values must be an object")
	text, ok := ser.save_to_text(doc.data)
	if !ok do return mcp.tool_fail("failed", "the document does not marshal")
	current, perr := json.parse_string(text, .JSON, true, context.temp_allocator)
	if perr != nil do return mcp.tool_fail("failed", "the document's JSON does not parse")
	merged := current.(json.Object)
	for k, v in values do merged[k] = v
	bytes, merr := json.marshal(merged, {spec = .JSON}, context.temp_allocator)
	if merr != nil do return mcp.tool_fail("failed", "the new values do not marshal")
	if !inspector.asset_doc_apply_json(doc.ref, .File, bytes) do return mcp.tool_fail("bad_request", "the values do not fit the asset")
	return mcp.tool_ok(struct {
		sub_id: i64,
		dirty:  bool,
	}{sub_id = i64(doc.ref.local_id), dirty = doc.dirty})
}
