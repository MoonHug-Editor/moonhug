package engine_tests

// GameObject > Create Prefab (scene_windows/prefab_create.odin): an object
// becomes a prefab file and an instance of it in its place, one undo step.
// References are tested in the three directions: from the scene into the
// object (moved to the instance), from the object out to the scene (empty in
// the file, an override on the instance), within the object (kept).

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:packages/engine"
import "moonhug:packages/engine/editor/scene_windows"
import undo "moonhug:packages/engine/editor/undo"

@(private = "file")
_DIR :: "moonhug/tests/_fx_prefab_create"

@(private = "file")
_obj :: proc(name: string, parent: engine.Transform_Handle, pos: [3]f32) -> engine.Transform_Handle {
	tH := engine.transform_new(name, parent)
	engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)).position = pos
	return tH
}

// A Canvas on `from` whose render_camera names `at`: a reference field of
// the engine's own.
@(private = "file")
_aim :: proc(from, at: engine.Transform_Handle) {
	_, raw := engine.transform_add_comp(from, .Canvas)
	c := cast(^engine.Canvas)raw
	engine.type_reset_Canvas(c)
	c.render_camera = {local_id = engine.pool_get(&engine.ctx_world().transforms, engine.Handle(at)).local_id, handle = engine.Handle(at)}
}

@(private = "file")
_aimed :: proc(from: engine.Transform_Handle) -> engine.Transform_Handle {
	_, c := engine.transform_get_comp(from, engine.Canvas)
	if c == nil do return {}
	if !engine.pool_valid(&engine.ctx_world().transforms, c.render_camera.handle) do return {}
	return engine.Transform_Handle(c.render_camera.handle)
}

@(private = "file")
_child :: proc(tH: engine.Transform_Handle, i: int) -> engine.Transform_Handle {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	if t == nil || i >= len(t.children) do return {}
	return engine.Transform_Handle(t.children[i].handle)
}

@(private = "file")
_name :: proc(tH: engine.Transform_Handle) -> string {
	t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH))
	return t != nil ? t.name : ""
}

@(private = "file")
_num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float: return f64(n)
	}
	return -1
}

@(test)
test_create_prefab_puts_an_instance_in_place :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	os.make_directory(_DIR)
	defer _remove_tree(_DIR)
	engine.asset_db_init(_DIR)
	defer {
		engine.asset_db_shutdown()
		engine.scene_lib_shutdown()
	}
	asset_pipeline.asset_db_refresh()

	sc := tc_mem.scene
	root := engine.Transform_Handle(sc.root.handle)
	player := _obj("Player", root, {5, 0, 0})
	tank := _obj("Tank", root, {1, 2, 3})
	turret := _obj("Turret", tank, {0, 1, 0})
	_aim(player, turret) // into the object
	_aim(tank, player) // out of it
	_aim(turret, tank) // within it

	path := _DIR + "/Tank.scene"
	inst: engine.Transform_Handle
	{
		g := undo.group_begin("Create Prefab")
		defer undo.group_end(&g)
		inst = scene_windows.prefab_create(tank, path)
		undo.group_commit(&g)
	}
	if !testing.expect(t, inst != {}, "the object became an instance") do return

	// The instance stands where the object stood.
	testing.expect(t, engine.scene_find_nested_scene_for_host(sc, inst) != nil, "a prefab instance")
	testing.expect_value(t, _child(root, 1), inst)
	testing.expect_value(t, engine.pool_get(&tc_mem.world.transforms, engine.Handle(inst)).position, [3]f32{1, 2, 3})
	inst_turret := _child(inst, 0)
	testing.expect_value(t, _name(inst_turret), "Turret")

	// References: into it moved, out of it kept, within it kept.
	testing.expect_value(t, _aimed(player), inst_turret)
	testing.expect_value(t, _aimed(inst), player)
	testing.expect_value(t, _aimed(inst_turret), inst)
	ns := engine.scene_find_nested_scene_for_host(sc, inst)
	overridden := false
	if ns != nil do for ov in ns.overrides do if ov.property_path == "render_camera" do overridden = true
	testing.expect(t, overridden, "the reference out of the prefab is an override of the instance")

	// The file: its root at the origin, the reference out of it empty, the
	// one within it kept.
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, rerr == nil, "the prefab file is written") do return
	doc, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if !testing.expect(t, perr == nil, "the prefab file parses") do return
	file_root := doc.(json.Object)["root"].(json.Integer)
	for tr in doc.(json.Object)["transforms"].(json.Array) {
		o := tr.(json.Object)
		if o["local_id"].(json.Integer) != file_root do continue
		pos := o["position"].(json.Array)
		testing.expect(t, _num(pos[0]) == 0 && _num(pos[1]) == 0 && _num(pos[2]) == 0, "the root sits at the file's origin")
	}
	aims := make([dynamic]i64, context.temp_allocator)
	for c in doc.(json.Object)["components"].(json.Array) {
		if rc, has := c.(json.Object)["render_camera"]; has do append(&aims, i64(rc.(json.Object)["local_id"].(json.Integer)))
	}
	testing.expect_value(t, len(aims), 2)
	if len(aims) == 2 {
		testing.expect(t, (aims[0] == 0) != (aims[1] == 0), "the reference out of the prefab is empty in the file")
		testing.expect(t, aims[0] == file_root || aims[1] == file_root, "the one within it names the prefab's root")
	}

	// Undo puts the objects back, with the references to them.
	undo.apply_undo(s)
	back := _child(root, 1)
	testing.expect_value(t, _name(back), "Tank")
	testing.expect(t, engine.scene_find_nested_scene_for_host(sc, back) == nil, "no longer an instance")
	testing.expect_value(t, _aimed(player), _child(back, 0))
	testing.expect_value(t, _aimed(back), player)

	// Redo brings the instance back.
	undo.apply_redo(s)
	again := _child(root, 1)
	testing.expect(t, engine.scene_find_nested_scene_for_host(sc, again) != nil, "an instance again")
	testing.expect_value(t, _aimed(player), _child(again, 0))
	testing.expect_value(t, _aimed(again), player)
	testing.expect_value(t, _aimed(_child(again, 0)), again)
}

// A prefab instance inside the object stays a prefab instance in the file,
// and the new instance shows its content. What cannot become a prefab says
// why.
@(test)
test_create_prefab_keeps_instances_inside :: proc(t: ^testing.T) {
	fx: Fixture_Chain
	defer fixture_chain_destroy(&fx)
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	s := setup_undo(tc_mem)
	context.user_ptr = &tc_mem.uc
	defer teardown_undo(tc_mem, s)
	fx_ok: bool
	fx, fx_ok = fixture_chain_author(t, tc_mem, "moonhug/tests/_fx_prefab_create_nested")
	if !fx_ok do return
	path := strings.concatenate({fx.dir, "/Holder.scene"}, context.temp_allocator)
	defer os.remove(strings.concatenate({path, ".meta"}, context.temp_allocator))
	defer os.remove(path)
	sc := tc_mem.scene
	root := engine.Transform_Handle(sc.root.handle)
	bullet_instance := _child(root, 0)

	c_raw, _ := engine.asset_db_get_guid(fx.c_path)
	c_guid := engine.Asset_GUID(c_raw)
	holder := _obj("Holder", root, {0, 0, 0})
	if !testing.expect(t, engine.scene_instantiate_guid_nested(c_guid, holder) != {}, "c nests under the holder") do return

	testing.expect(t, scene_windows._prefab_refusal(root) != "", "a scene root cannot become a prefab")
	testing.expect(t, scene_windows._prefab_refusal(bullet_instance) != "", "nor a prefab instance")
	testing.expect(t, scene_windows._prefab_refusal(_child(bullet_instance, 0)) != "", "nor what is inside one")
	testing.expect_value(t, scene_windows._prefab_refusal(holder), "")

	inst: engine.Transform_Handle
	{
		g := undo.group_begin("Create Prefab")
		defer undo.group_end(&g)
		inst = scene_windows.prefab_create(holder, path)
		undo.group_commit(&g)
	}
	if !testing.expect(t, inst != {}, "the holder became an instance") do return

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, rerr == nil, "the prefab file is written") do return
	doc, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)
	if !testing.expect(t, perr == nil, "the prefab file parses") do return
	records := doc.(json.Object)["nested_scenes"].(json.Array)
	testing.expect_value(t, len(records), 1)

	inner := _child(inst, 0)
	testing.expect(t, engine.scene_find_nested_scene_for_host(sc, inner) != nil, "the nested c is an instance inside the new one")
	content := _child(inner, 0)
	_, light := engine.transform_get_comp(content, engine.Light)
	testing.expect(t, light != nil, "with c's content")
}
