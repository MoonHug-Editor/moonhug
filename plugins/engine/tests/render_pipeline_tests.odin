package engine_tests

// The render node registry (plugins/engine/render_node_registry.odin) and the render
// pipeline that places nodes (render_pipeline.odin): a pipeline runs its
// frame lane once and a slot's lane in canvas order, with each instance's
// own settings.

import "core:encoding/json"
import "core:testing"

@(private = "file")
_settings_json :: proc(key: string, value: f64) -> json.Value {
	obj := make(json.Object)
	obj[key] = json.Float(value)
	return obj
}
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"

@(private = "file")
_calls: [dynamic]string

@(private = "file")
Tint_Settings :: struct {
	amount: f32,
}

@(private = "file")
_tint_defaults := Tint_Settings{amount = 0.5}

@(private = "file")
_node_frame :: proc(ctx: ^engine.Render_Ctx) { append(&_calls, "frame") }
@(private = "file")
_node_a :: proc(ctx: ^engine.Render_Ctx) { append(&_calls, "a") }
@(private = "file")
_node_tint :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Tint_Settings)(ctx.settings)
	append(&_calls, s.amount == 0.5 ? "tint:default" : "tint:set")
	ctx.clear = {1, 0, 0, 1} // nodes see one shared ctx
}

@(private = "file")
_scene_reads := [?]string{"scene", "never_written"}

// Reads the scene and a target nothing takes: both come back nil.
@(private = "file")
_node_reader :: proc(ctx: ^engine.Render_Ctx) {
	scene := engine.render_input(ctx, "scene")
	missing := engine.render_input(ctx, "never_written")
	append(&_calls, scene == nil && missing == nil ? "reader:nil" : "reader:found")
}

@(private = "file")
_register_test_nodes :: proc() {
	if engine.render_node_find("t_frame") != nil do return
	engine.render_node_register({name = "t_reader", pkg = "tests", reads = _scene_reads[:], run = _node_reader})
	engine.render_node_register({name = "t_frame", pkg = "tests", frame = true, run = _node_frame})
	engine.render_node_register({name = "t_a", pkg = "tests", run = _node_a})
	engine.render_node_register({
		name = "t_tint", pkg = "tests", run = _node_tint,
		settings_tid = typeid_of(Tint_Settings), settings_ptr_tid = typeid_of(^Tint_Settings),
		settings_size = size_of(Tint_Settings), settings_default = &_tint_defaults,
	})
}

// A pipeline placed by hand runs its frame lane once, then the slot's nodes
// in lane order, and a placed node reads the settings stored for it.
@(test)
test_render_pipeline_runs_lanes_in_order :: proc(t: ^testing.T) {
	_register_test_nodes()
	_calls = make([dynamic]string)
	defer delete(_calls)

	p: engine.Render_Pipeline
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	engine.pipeline_add_slot(&p, "Second")
	engine.pipeline_add_node(&p, "t_frame", "")
	tint := engine.pipeline_add_node(&p, "t_tint", engine.MAIN_SLOT)
	engine.pipeline_add_node(&p, "t_a", engine.MAIN_SLOT, 0) // inserted before the tint
	engine.pipeline_add_node(&p, "t_a", "Second")
	engine.pipeline_find_node(&p, tint).settings = _settings_json("amount", 2)
	lane := engine.pipeline_lane(&p, engine.MAIN_SLOT)
	testing.expect(t, len(lane) == 2 && lane[0].node == "t_a" && lane[1].node == "t_tint")

	// The built-in frame is the active pipeline in a test (no asset db):
	// previewing with its guid replaces it.
	engine.render_pipeline_preview({}, p)
	engine.cleanup_Render_Pipeline(&p)
	defer engine.render_pipeline_preview({}, {}) // leaves an empty pipeline behind, not the test nodes

	ctx: engine.Render_Ctx
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	testing.expect(t, engine.render_pipeline_run("Second", &ctx))
	testing.expect_value(t, len(_calls), 4)
	if len(_calls) != 4 do return
	testing.expect_value(t, _calls[0], "frame") // once, before any slot
	testing.expect_value(t, _calls[1], "a")
	testing.expect_value(t, _calls[2], "tint:set")
	testing.expect_value(t, _calls[3], "a") // the frame lane did not run again for Second
	testing.expect_value(t, ctx.clear, [4]f32{1, 0, 0, 1})
	testing.expect(t, ctx.node == nil, "the ctx forgets the node after the run")

	gfx.frame_index += 1
	clear(&_calls)
	testing.expect(t, engine.render_pipeline_run("NoSuchSlot", &ctx)) // falls back to Main with a warning
	testing.expect_value(t, len(_calls), 3)

	_check_mute_and_absent_inputs(t)
}

// A muted node is skipped, frame lane and slot alike, through the preview
// the window uses (which copies the document), and runs again once unmuted.
// A read of the scene or of a target nothing took this frame is nil. Part of
// the lanes test: the active pipeline, _calls and the frame dedupe are
// shared state.
@(private = "file")
_check_mute_and_absent_inputs :: proc(t: ^testing.T) {
	clear(&_calls)
	p: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&p)
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	f := engine.pipeline_add_node(&p, "t_frame", "")
	a := engine.pipeline_add_node(&p, "t_a", engine.MAIN_SLOT)
	engine.pipeline_add_node(&p, "t_reader", engine.MAIN_SLOT)
	engine.pipeline_find_node(&p, f).muted = true
	engine.pipeline_find_node(&p, a).muted = true

	clone := engine.pipeline_clone(p)
	testing.expect(t, engine.pipeline_find_node(&clone, f).muted, "the clone keeps muted")
	engine.cleanup_Render_Pipeline(&clone)

	engine.render_pipeline_preview({}, p)
	gfx.frame_index += 1
	ctx: engine.Render_Ctx
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	testing.expect_value(t, len(_calls), 1)
	if len(_calls) == 1 do testing.expect_value(t, _calls[0], "reader:nil")

	engine.pipeline_find_node(&p, f).muted = false
	engine.pipeline_find_node(&p, a).muted = false
	engine.render_pipeline_preview({}, p)
	gfx.frame_index += 1
	clear(&_calls)
	ctx = {}
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	testing.expect_value(t, len(_calls), 3)
	if len(_calls) == 3 {
		testing.expect_value(t, _calls[0], "frame")
		testing.expect_value(t, _calls[1], "a")
		testing.expect_value(t, _calls[2], "reader:nil")
	}
}

// Moving a node changes its lane position, and a port binding changes the
// target name an instance runs with while the node's declaration stays.
@(test)
test_render_pipeline_move_and_bind :: proc(t: ^testing.T) {
	_register_test_nodes()
	p: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&p)
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	a := engine.pipeline_add_node(&p, "t_a", engine.MAIN_SLOT)
	b := engine.pipeline_add_node(&p, "t_tint", engine.MAIN_SLOT)
	testing.expect(t, engine.pipeline_move_node(&p, b, engine.MAIN_SLOT, 0))
	lane := engine.pipeline_lane(&p, engine.MAIN_SLOT)
	testing.expect(t, lane[0].id == b && lane[1].id == a, "the tint moved first")
	testing.expect(t, engine.pipeline_move_node(&p, a, "Other"))
	testing.expect_value(t, len(engine.pipeline_lane(&p, engine.MAIN_SLOT)), 1)
	testing.expect_value(t, engine.pipeline_lane(&p, "Other")[0].slot, "Other")

	e := engine.pipeline_find_node(&p, b)
	engine.pipeline_entry_bind(e, "hdr", "hdr_wide")
	testing.expect_value(t, engine.pipeline_entry_port(e^, "hdr"), "hdr_wide")
	testing.expect_value(t, engine.pipeline_entry_port(e^, "other"), "other")
	engine.pipeline_entry_bind(e, "hdr", "") // unbinds
	testing.expect_value(t, len(e.binds), 0)

	// Bindings survive the clone and the JSON round trip.
	engine.pipeline_entry_bind(e, "hdr", "hdr_wide")
	c := engine.pipeline_clone(p)
	defer engine.cleanup_Render_Pipeline(&c)
	testing.expect_value(t, engine.pipeline_entry_port(engine.pipeline_find_node(&c, b)^, "hdr"), "hdr_wide")
	data, err := json.marshal(p, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil)
	back, ok := engine.pipeline_parse(data)
	defer engine.cleanup_Render_Pipeline(&back)
	testing.expect(t, ok && engine.pipeline_entry_port(engine.pipeline_find_node(&back, b)^, "hdr") == "hdr_wide")
}

// A new pipeline places the engine's frame on one Main slot, and survives a
// JSON round trip with its settings.
@(test)
test_render_pipeline_reset_and_roundtrip :: proc(t: ^testing.T) {
	p: engine.Render_Pipeline
	engine.reset_Render_Pipeline(&p)
	defer engine.cleanup_Render_Pipeline(&p)
	testing.expect_value(t, len(p.slots), 1)
	testing.expect_value(t, p.slots[0].name, engine.MAIN_SLOT)
	testing.expect_value(t, len(p.nodes), 6)
	testing.expect_value(t, p.nodes[0].node, "shadow_pass")
	testing.expect_value(t, p.nodes[0].slot, "")
	testing.expect_value(t, p.nodes[5].node, "final_blit")
	p.nodes[0].settings = _settings_json("bias", 0.01)

	data, err := json.marshal(p, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil)
	back, ok := engine.pipeline_parse(data)
	defer engine.cleanup_Render_Pipeline(&back)
	testing.expect(t, ok, "a pipeline parses back")
	testing.expect_value(t, len(back.nodes), 6)
	testing.expect_value(t, back.next_id, p.next_id)
	bias, has := back.nodes[0].settings.(json.Object)["bias"]
	testing.expect(t, has && bias.(json.Float) == 0.01, "the settings JSON round-trips")

	clone := engine.pipeline_clone(back)
	defer engine.cleanup_Render_Pipeline(&clone)
	testing.expect_value(t, len(clone.nodes), 6)
	engine.pipeline_remove_slot(&clone, engine.MAIN_SLOT)
	testing.expect_value(t, len(clone.nodes), 1) // only the frame lane remains
	testing.expect_value(t, len(clone.slots), 0)
}

// The generated registrations keep their reads and writes after the
// registration proc returns: the slices point at file-scope arrays, not at
// the proc's stack (a stack literal read back as garbage and crashed the
// pipeline window). And the declarations parsed as written.
@(test)
test_render_nodes_registered_declarations :: proc(t: ^testing.T) {
	// Overwrite the stack the registration ran on, so a dangling slice reads junk.
	junk: [4096]u8
	for &b, i in junk do b = u8(i * 7)
	seen_read := false
	for n in engine.render_nodes() {
		testing.expect(t, n.pkg != "", "every node names its package")
		for s in n.reads {
			seen_read = true
			testing.expectf(t, len(s) > 0 && len(s) < 64, "%s reads a sane name, got length %d", n.name, len(s))
		}
		for d in n.writes {
			testing.expectf(t, len(d.name) > 0 && len(d.name) < 64, "%s writes a sane name, got length %d", n.name, len(d.name))
			testing.expectf(t, d.px > 0 || d.scale > 0, "%s writes %s without a size", n.name, d.name)
			if n.frame do testing.expectf(t, d.px > 0, "%s is per frame, its write %s needs fixed pixels", n.name, d.name)
		}
		if n.settings_size > 0 do testing.expectf(t, n.settings_default != nil, "%s declares settings without defaults", n.name)
	}
	testing.expect(t, seen_read, "some node declares a read")
	_ = junk

	opaque := engine.render_node_find("scene_opaque")
	testing.expect(t, opaque != nil, "the engine's scene_opaque is registered")
	if opaque != nil {
		testing.expect_value(t, len(opaque.writes), 1)
		testing.expect_value(t, opaque.writes[0].name, engine.HDR_TARGET)
		testing.expect_value(t, opaque.writes[0].format, gfx.Target_Format.HDR)
		testing.expect(t, opaque.writes[0].final, "the scene image is the first final")
	}
	shadow := engine.render_node_find("shadow_pass")
	testing.expect(t, shadow != nil && shadow.frame && shadow.writes[0].px == i32(engine.SHADOW_MAP_SIZE))
	testing.expect(t, shadow != nil && shadow.settings_tid == typeid_of(engine.Shadow_Settings), "shadow_pass declares its settings")
}
