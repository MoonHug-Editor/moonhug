package sequencer_tests

import "core:testing"
import "moonhug:packages/engine"
import seq "moonhug:packages/sequencer"
import tweens "moonhug:packages/sequencer/tweens"
import common "moonhug:tests/common"

// Union fields round-trip through the generic guid-keyed serializers. The
// unions are #no_nil: their zero value is the FIRST variant, never nil, so
// a freshly added list element is a real variant and always marshals to a
// guid-tagged object. A nilable union would write bare `null`, which
// union_unmarshal cannot read back — the whole owning component then fails
// to parse and the loader preserves it verbatim as an unknown component
// (the object shows "Missing Component" and its list vanishes).
@(test)
test_union_field_round_trips :: proc(t: ^testing.T) {
	tc_mem := new(common.TestCtx)
	defer free(tc_mem)
	s := common.setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer common.teardown_undo(tc_mem, s)

	root := engine.transform_new("Stage")
	engine.scene_set_root(tc_mem.scene, root)
	clip := engine.transform_new("clip", root)
	_, raw := engine.transform_add_comp(clip, .ClipTween)
	tclip := cast(^seq.ClipTween)raw
	testing.expect(t, tclip != nil)
	if tclip == nil do return
	// Element 0 is the DEFAULT (what "Add Element" produces before a variant
	// is picked); element 1 is explicitly chosen. Both must survive.
	append(&tclip.tweens, seq.TweenUnion{})
	append(&tclip.tweens, seq.TweenUnion(tweens.TweenMoveLocalTo{to = {5, 0, 0}}))

	bytes, ok := engine.scene_serialize(tc_mem.scene)
	testing.expect(t, ok, "serialize")
	if !ok do return
	defer delete(bytes)
	reloaded := engine.scene_reload_in_place_bytes(tc_mem.scene, bytes)
	testing.expect(t, reloaded != nil, "reload")
	if reloaded == nil do return
	tc_mem.scene = reloaded

	testing.expect_value(t, len(reloaded.unknown_components), 0)

	live: ^seq.ClipTween
	{
		w := &tc_mem.world
		it := engine.pool_iterator(&w.transforms)
		for tr, _ in engine.pool_next(&it) {
			for c in tr.components {
				if c.handle.type_key == .ClipTween {
					live = cast(^seq.ClipTween)engine.world_pool_get(w, c.handle)
				}
			}
		}
	}
	testing.expect(t, live != nil, "the component loaded rather than being stashed")
	if live == nil do return
	testing.expect_value(t, len(live.tweens), 2)
	if len(live.tweens) != 2 do return
	_, is_move := live.tweens[1].(tweens.TweenMoveLocalTo)
	testing.expect(t, is_move, "the picked variant survives beside the default")
}
