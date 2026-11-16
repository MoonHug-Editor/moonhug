package engine_tests

// The drop rules (moonhug/editor/drag): what a drag's items match, and what
// a drop does on the Hierarchy and on a Project folder. A rule asked while
// the drag hovers changes nothing and says what it would do.

import "core:os"
import "core:strings"
import "core:testing"
import "moonhug:editor/drag"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"

@(private = "file")
_kids :: proc(tH: engine.Transform_Handle) -> string {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return ""
	names := make([dynamic]string, context.temp_allocator)
	for c in t.children do if ct := engine.pool_get(&w.transforms, c.handle); ct != nil do append(&names, ct.name)
	return strings.join(names[:], " ", context.temp_allocator)
}

@(test)
test_drop_items_match_what_a_rule_names :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	obj := engine.transform_new("A")
	asset := engine.PPtr{guid = {0 = 1}}
	testing.expect(t, drag.matches("object", {obj}), "an object is an object")
	testing.expect(t, !drag.matches("asset", {obj}), "and not an asset")
	testing.expect(t, drag.matches("asset", {asset}), "an asset is an asset")
	testing.expect(t, !drag.matches("object", {obj, asset}), "a mix matches no rule")
	testing.expect(t, !drag.matches("asset:scene", {asset}), "an asset the database does not know has no kind")
	testing.expect(t, !drag.matches("object", {}), "nothing matches nothing")
}

@(test)
test_drop_objects_in_hierarchy :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	a := engine.transform_new("A", root)
	b := engine.transform_new("B", root)
	c := engine.transform_new("C", root)

	// Asked while hovering: what it would do, nothing moved.
	hint, taken := drag.run({c}, drag.Hierarchy_Place{parent = root, index = 0}, false)
	testing.expect(t, taken, "the Hierarchy takes an object")
	testing.expect(t, strings.has_prefix(hint, "Move C under"), "and says what the drop does")
	testing.expect_value(t, _kids(root), "A B C")

	// Before the first row, then after the last.
	drag.run({c}, drag.Hierarchy_Place{parent = root, index = 0}, true)
	testing.expect_value(t, _kids(root), "C A B")
	drag.run({c}, drag.Hierarchy_Place{parent = root, index = 3}, true)
	testing.expect_value(t, _kids(root), "A B C")

	// Two objects onto a row: its children, in their order. One undo step.
	drag.run({a, b}, drag.Hierarchy_Place{parent = c, index = -1}, true)
	testing.expect_value(t, _kids(c), "A B")
	testing.expect_value(t, _kids(root), "C")
	undo.apply_undo(s)
	testing.expect_value(t, _kids(root), "A B C")

	// Never under itself or its own children.
	drag.run({a}, drag.Hierarchy_Place{parent = c, index = -1}, true)
	_, taken = drag.run({c}, drag.Hierarchy_Place{parent = a, index = -1}, false)
	testing.expect(t, !taken, "C does not go under its own child")
	_, taken = drag.run({root}, drag.Hierarchy_Place{parent = c, index = -1}, false)
	testing.expect(t, !taken, "the scene root stays")
}

@(test)
test_drop_assets_in_hierarchy_and_on_its_background :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_drop_rules")
	if !fx_ok do return
	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	c_raw, _ := engine.asset_db_get_guid(fx.c_path)
	c := engine.PPtr{guid = engine.Asset_GUID(c_raw)}

	// On the background a scene opens beside the loaded ones, on a row it is
	// an instance: the scene rule is asked before the asset rule.
	hint, taken := drag.run({c}, drag.Hierarchy_Place{index = -1}, false)
	testing.expect(t, taken && strings.has_prefix(hint, "Open c"), "the background opens a scene")
	hint, taken = drag.run({c}, drag.Hierarchy_Place{parent = root, index = 0}, false)
	testing.expect(t, taken && hint == "Place c", "a row places it")

	before := _kids(root)
	drag.run({c}, drag.Hierarchy_Place{parent = root, index = 0}, true)
	testing.expect_value(t, _kids(root), strings.concatenate({"c ", before}, context.temp_allocator))
	first := engine.Transform_Handle(engine.pool_get(&tc_mem.world.transforms, engine.Handle(root)).children[0].handle)
	testing.expect(t, engine.scene_find_nested_scene_for_host(tc_mem.scene, first) != nil, "an instance, first")
}

@(test)
test_drop_objects_on_a_project_folder :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	dir :: "moonhug/tests/_fx_drop_project"
	os.make_directory(dir)
	defer _remove_tree(dir)
	engine.asset_db_init(dir)
	defer {
		engine.asset_db_shutdown()
		engine.scene_lib_shutdown()
	}
	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	tank := engine.transform_new("Tank", root)

	hint, taken := drag.run({tank}, drag.Project_Place{folder = dir}, false)
	testing.expect(t, taken, "a Project folder takes an object")
	testing.expect_value(t, hint, "Make prefab Tank.scene")
	testing.expect(t, !os.exists(dir + "/Tank.scene"), "asking writes nothing")

	drag.run({tank}, drag.Project_Place{folder = dir}, true)
	testing.expect(t, os.exists(dir + "/Tank.scene"), "the drop writes the prefab")
	inst := engine.Transform_Handle(engine.pool_get(&tc_mem.world.transforms, engine.Handle(root)).children[0].handle)
	testing.expect(t, engine.scene_find_nested_scene_for_host(tc_mem.scene, inst) != nil, "and the object is its instance")

	// An instance is a prefab already: the folder does not take it.
	_, taken = drag.run({inst}, drag.Project_Place{folder = dir}, false)
	testing.expect(t, !taken, "an instance is not taken")
}
