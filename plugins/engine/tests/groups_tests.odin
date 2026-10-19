package engine_tests

// Groups (groups.odin): the Groups component's bits are indexed by the game
// lifecycle hooks into alive and active lists, groups_set moves an object
// between lists, and the names come from the Group Names asset through the
// "group" layer domain.

import "core:testing"
import "moonhug:packages/engine"

@(private = "file")
_grouped :: proc(name: string, parent: engine.Transform_Handle, mask: u32) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	_, raw := engine.transform_add_comp(tH, .Groups)
	(cast(^engine.Groups)raw).groups = mask
	return tH
}

@(private = "file")
_has :: proc(list: []engine.Transform_Handle, tH: engine.Transform_Handle) -> bool {
	for h in list do if h == tH do return true
	return false
}

@(test)
test_groups_index_follows_lifecycle :: proc(t: ^testing.T) {
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)

	ENEMY, BOSS :: 0, 1
	root := engine.Transform_Handle(tc.scene.root.handle)
	a := _grouped("A", root, 1 << ENEMY)
	b := _grouped("B", root, 1 << ENEMY | 1 << BOSS)
	c := _grouped("C", root, 1 << BOSS)
	if ct := engine.pool_get(&tc.world.transforms, engine.Handle(c)); ct != nil do ct.is_active = false
	testing.expect(t, engine.in_group(b, BOSS) && !engine.in_group(a, BOSS), "in_group reads the bits in every mode")
	testing.expect_value(t, len(engine.group_alive(ENEMY)), 0)

	engine.application_set_playing(true)
	defer engine.application_set_playing(false)
	testing.expect_value(t, len(engine.group_alive(ENEMY)), 2)
	testing.expect_value(t, len(engine.group_alive(BOSS)), 2)
	testing.expect(t, _has(engine.group_alive(BOSS), c), "an inactive object is alive in its groups")
	testing.expect(t, !_has(engine.group_active(BOSS), c), "but not active")
	testing.expect_value(t, len(engine.group_active(ENEMY)), 2)

	engine.transform_set_active(c, true)
	testing.expect(t, _has(engine.group_active(BOSS), c), "activation joins the active list")
	_, gb := engine.transform_get_comp(b, engine.Groups)
	engine.comp_set_enabled(gb, false)
	testing.expect(t, _has(engine.group_alive(ENEMY), b) && !_has(engine.group_active(ENEMY), b), "a disabled component leaves only the active lists")

	// A membership change at runtime moves the object between lists.
	_, ga := engine.transform_get_comp(a, engine.Groups)
	engine.groups_set(ga, 1 << BOSS)
	testing.expect(t, !_has(engine.group_alive(ENEMY), a), "left the old group")
	testing.expect(t, _has(engine.group_alive(BOSS), a) && _has(engine.group_active(BOSS), a), "joined the new one, active too")

	engine.transform_destroy(a)
	testing.expect(t, !_has(engine.group_alive(BOSS), a), "a destroy leaves the groups")

	// A component added during play awakes with no groups. An editor write of
	// its bits reaches the lists through the undo stack's value_written hook.
	d := engine.transform_new("D", root)
	owned, raw := engine.transform_add_comp(d, .Groups)
	testing.expect(t, !_has(engine.group_alive(ENEMY), d), "no bits, no group")
	(cast(^engine.Groups)raw).groups = 1 << ENEMY
	engine.editor_value_written(owned.handle)
	testing.expect(t, _has(engine.group_alive(ENEMY), d) && _has(engine.group_active(ENEMY), d), "the written bits join the lists")
	(cast(^engine.Groups)raw).groups = 0
	engine.editor_value_written(owned.handle)
	testing.expect(t, !_has(engine.group_alive(ENEMY), d), "cleared bits leave them")

	engine.application_set_playing(false)
	testing.expect_value(t, len(engine.group_alive(ENEMY)), 0)
	testing.expect_value(t, len(engine.group_active(BOSS)), 0)
}

@(test)
test_group_names_domain :: proc(t: ^testing.T) {
	g: engine.Group_Names
	engine.reset_Group_Names(&g)
	defer engine.cleanup_Group_Names(&g)
	for n in g.names do testing.expect_value(t, n, "")

	names := engine.layer_names(engine.GROUP_DOMAIN)
	testing.expect(t, names != nil, "the engine registers the group domain")
	g.names[2] = "Enemy"
	engine.group_names_preview(engine.groups_settings.group_names, g)
	defer {
		g.names[2] = ""
		engine.group_names_preview(engine.groups_settings.group_names, g)
	}
	testing.expect_value(t, engine.group_index("Enemy"), 2)
	testing.expect_value(t, engine.layer_index(engine.GROUP_DOMAIN, "Boss"), -1)
}
