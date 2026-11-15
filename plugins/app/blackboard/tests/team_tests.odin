package app_blackboard_tests

// A value type another plugin adds (app_blackboard.Team): an entry holds it,
// a slot of its type reads it, and it saves and loads.

import "core:testing"
import "moonhug:libs/slots"
import app_blackboard "moonhug:packages/app/blackboard"
import blackboard "moonhug:packages/blackboard"
import "moonhug:packages/engine"
import common "moonhug:tests/common"

@(test)
test_blackboard_holds_a_team :: proc(t: ^testing.T) {
	tc := new(common.TestCtx)
	defer free(tc)
	common.setup(tc)
	context.user_ptr = &tc.uc
	defer common.teardown(tc)

	vt, listed := blackboard.value_type_of(app_blackboard.Team)
	testing.expect(t, listed && vt.name == "Team", "the inspector lists Team")

	squad := engine.transform_new("Squad")
	engine.scene_set_root(tc.scene, squad)
	member := engine.transform_new("Member", squad)
	_, raw := engine.transform_add_comp(squad, .Blackboard)
	b := cast(^blackboard.Blackboard)raw
	blackboard.entry_add(b, "team").value = app_blackboard.Team.Blue
	key := blackboard.entry_key(&b.entries[0])

	testing.expect_value(t, slots.get(key, app_blackboard.Team.Red, slots.scope_of(member)), app_blackboard.Team.Blue)
	team, ok := blackboard.get(member, "team", app_blackboard.Team)
	testing.expect(t, ok && team == .Blue, "get reads the team by name")
	testing.expect_value(t, len(slots.scope_entries(member, app_blackboard.Team)), 1)

	data, saved := engine.scene_serialize(tc.scene)
	testing.expect(t, saved, "the scene saves")
	if !saved do return
	defer delete(data)
	reloaded := engine.scene_reload_in_place_bytes(tc.scene, data)
	testing.expect(t, reloaded != nil, "the scene loads")
	if reloaded == nil do return
	tc.scene = reloaded
	lb := blackboard.nearest(engine.Transform_Handle(reloaded.root.handle))
	testing.expect(t, lb != nil && len(lb.entries) == 1 && lb.entries[0].value == blackboard.Blackboard_Value(app_blackboard.Team.Blue), "the team loads back")
}
