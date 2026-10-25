package shadergraph_tests

// A Shader Graph undo step names the graph asset it edits, so its steps go
// with the asset: a Discard of the open graph and a delete of the file both
// purge them, and another graph's steps stay.

import "core:encoding/uuid"
import "core:strings"
import "core:testing"
import "moonhug:editor/undo"
import core "moonhug:libs/core"
import sgu "moonhug:packages/shadergraph/editor/undo_cmd"
import common "moonhug:tests/common"

@(test)
shadergraph_undo_steps_go_with_their_asset :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	s := common.setup_undo(tc)
	context.user_ptr = &tc.uc
	defer common.teardown_undo(tc, s)

	edit :: proc(path: string, guid: core.Asset_GUID) -> sgu.Shader_Graph_Edit {
		return {path = strings.clone(path), guid = guid, before = strings.clone("{}"), after = strings.clone("{}")}
	}
	discarded := core.Asset_GUID(uuid.read("5b8e2c41-7d93-4f0a-9c16-2e4b7a1d8f03") or_else uuid.Identifier{})
	kept := core.Asset_GUID(uuid.read("9e14a7c2-3b58-4d6f-8a20-7c1e5f9b4d62") or_else uuid.Identifier{})
	undo.push(s, edit("assets/A.shadergraph", discarded), "Edit A")
	undo.push(s, edit("assets/B.shadergraph", kept), "Edit B")
	undo.push(s, edit("assets/A.shadergraph", discarded), "Edit A again")

	undo.purge_asset(s, discarded)
	testing.expect_value(t, len(s.items), 1)
	testing.expect_value(t, s.items[0].cmd.(sgu.Shader_Graph_Edit).guid, kept)
}
