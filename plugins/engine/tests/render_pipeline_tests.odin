package engine_tests

// The render step registry (plugins/engine/render_step_registry.odin) and the render
// pipeline that places steps (render_pipeline.odin): a pipeline runs its
// frame lane once and a slot's lane in canvas order, with each instance's
// own settings.

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
_settings_json :: proc(key: string, value: f64) -> json.Value {
	obj := make(json.Object)
	obj[key] = json.Float(value)
	return obj
}
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import "moonhug:packages/engine"
import rpv "moonhug:packages/engine/editor/render_pipeline_view"
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
_step_frame :: proc(ctx: ^engine.Render_Ctx) { append(&_calls, "frame") }
@(private = "file")
_step_a :: proc(ctx: ^engine.Render_Ctx) { append(&_calls, "a") }
@(private = "file")
_step_tint :: proc(ctx: ^engine.Render_Ctx) {
	s := (^Tint_Settings)(ctx.settings)
	append(&_calls, s.amount == 0.5 ? "tint:default" : "tint:set")
	ctx.clear = {1, 0, 0, 1} // steps see one shared ctx
}

@(private = "file")
_scene_reads := [?]string{"scene", "never_written"}

// Reads the scene and a target nothing takes: both come back nil.
@(private = "file")
_step_reader :: proc(ctx: ^engine.Render_Ctx) {
	scene := engine.render_input(ctx, "scene")
	missing := engine.render_input(ctx, "never_written")
	append(&_calls, scene == nil && missing == nil ? "reader:nil" : "reader:found")
}

@(private = "file")
_register_test_steps :: proc() {
	if engine.render_step_find("t_frame") != nil do return
	engine.render_step_register({name = "t_reader", pkg = "tests", reads = _scene_reads[:], run = _step_reader})
	engine.render_step_register({name = "t_frame", pkg = "tests", frame = true, run = _step_frame})
	engine.render_step_register({name = "t_a", pkg = "tests", run = _step_a})
	engine.render_step_register({
		name = "t_tint", pkg = "tests", run = _step_tint,
		settings_tid = typeid_of(Tint_Settings), settings_ptr_tid = typeid_of(^Tint_Settings),
		settings_size = size_of(Tint_Settings), settings_default = &_tint_defaults,
	})
}

// A pipeline placed by hand runs its frame lane once, then the slot's steps
// in lane order, and a placed step reads the settings stored for it.
@(test)
test_render_pipeline_runs_lanes_in_order :: proc(t: ^testing.T) {
	_register_test_steps()
	_calls = make([dynamic]string)
	defer delete(_calls)

	p: engine.Render_Pipeline
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	engine.pipeline_add_slot(&p, "Second")
	engine.pipeline_add_step(&p, "t_frame", "")
	tint := engine.pipeline_add_step(&p, "t_tint", engine.MAIN_SLOT)
	engine.pipeline_add_step(&p, "t_a", engine.MAIN_SLOT, 0) // inserted before the tint
	engine.pipeline_add_step(&p, "t_a", "Second")
	engine.pipeline_find_step(&p, tint).settings = _settings_json("amount", 2)
	lane := engine.pipeline_lane(&p, engine.MAIN_SLOT)
	testing.expect(t, len(lane) == 2 && lane[0].step == "t_a" && lane[1].step == "t_tint")

	// The built-in frame is the active pipeline in a test (no asset db):
	// previewing with its guid replaces it.
	engine.render_pipeline_preview({}, p)
	engine.cleanup_Render_Pipeline(&p)
	defer engine.render_pipeline_preview({}, {}) // leaves an empty pipeline behind, not the test steps

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
	testing.expect(t, ctx.step == nil, "the ctx forgets the step after the run")

	gfx.frame_index += 1
	clear(&_calls)
	testing.expect(t, engine.render_pipeline_run("NoSuchSlot", &ctx)) // falls back to Main with a warning
	testing.expect_value(t, len(_calls), 3)

	_check_mute_and_absent_inputs(t)
}

// A muted step is skipped, frame lane and slot alike, through the preview
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
	f := engine.pipeline_add_step(&p, "t_frame", "")
	a := engine.pipeline_add_step(&p, "t_a", engine.MAIN_SLOT)
	engine.pipeline_add_step(&p, "t_reader", engine.MAIN_SLOT)
	engine.pipeline_find_step(&p, f).muted = true
	engine.pipeline_find_step(&p, a).muted = true

	clone := engine.pipeline_clone(p)
	testing.expect(t, engine.pipeline_find_step(&clone, f).muted, "the clone keeps muted")
	engine.cleanup_Render_Pipeline(&clone)

	engine.render_pipeline_preview({}, p)
	gfx.frame_index += 1
	ctx: engine.Render_Ctx
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	testing.expect_value(t, len(_calls), 1)
	if len(_calls) == 1 do testing.expect_value(t, _calls[0], "reader:nil")

	engine.pipeline_find_step(&p, f).muted = false
	engine.pipeline_find_step(&p, a).muted = false
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

// Moving a step changes its lane position, and a port binding changes the
// target name an instance runs with while the step's declaration stays.
@(test)
test_render_pipeline_move_and_bind :: proc(t: ^testing.T) {
	_register_test_steps()
	p: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&p)
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	a := engine.pipeline_add_step(&p, "t_a", engine.MAIN_SLOT)
	b := engine.pipeline_add_step(&p, "t_tint", engine.MAIN_SLOT)
	testing.expect(t, engine.pipeline_move_step(&p, b, engine.MAIN_SLOT, 0))
	lane := engine.pipeline_lane(&p, engine.MAIN_SLOT)
	testing.expect(t, lane[0].id == b && lane[1].id == a, "the tint moved first")
	testing.expect(t, engine.pipeline_move_step(&p, a, "Other"))
	testing.expect_value(t, len(engine.pipeline_lane(&p, engine.MAIN_SLOT)), 1)
	testing.expect_value(t, engine.pipeline_lane(&p, "Other")[0].slot, "Other")

	e := engine.pipeline_find_step(&p, b)
	engine.pipeline_entry_bind(e, "hdr", "hdr_wide")
	testing.expect_value(t, engine.pipeline_entry_port(e^, "hdr"), "hdr_wide")
	testing.expect_value(t, engine.pipeline_entry_port(e^, "other"), "other")
	engine.pipeline_entry_bind(e, "hdr", "") // unbinds
	testing.expect_value(t, len(e.binds), 0)

	// Bindings survive the clone and the JSON round trip.
	engine.pipeline_entry_bind(e, "hdr", "hdr_wide")
	c := engine.pipeline_clone(p)
	defer engine.cleanup_Render_Pipeline(&c)
	testing.expect_value(t, engine.pipeline_entry_port(engine.pipeline_find_step(&c, b)^, "hdr"), "hdr_wide")
	data, err := json.marshal(p, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil)
	back, ok := engine.pipeline_parse(data)
	defer engine.cleanup_Render_Pipeline(&back)
	testing.expect(t, ok && engine.pipeline_entry_port(engine.pipeline_find_step(&back, b)^, "hdr") == "hdr_wide")
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
	// The frame lane (environment, spot and point shadows), then Main from
	// the directional cascades and scene_opaque through the sky to the
	// final blit.
	testing.expect_value(t, len(p.steps), 9)
	testing.expect_value(t, p.steps[0].step, "environment_pass")
	testing.expect_value(t, p.steps[1].step, "shadow_atlas")
	testing.expect_value(t, p.steps[1].slot, "")
	testing.expect_value(t, p.steps[2].step, "shadow_cascades")
	testing.expect_value(t, p.steps[2].slot, engine.MAIN_SLOT)
	testing.expect_value(t, p.steps[4].step, "scene_sky")
	testing.expect_value(t, p.steps[8].step, "final_blit")
	p.steps[1].settings = _settings_json("bias", 0.01)

	data, err := json.marshal(p, {spec = .JSON}, context.temp_allocator)
	testing.expect(t, err == nil)
	back, ok := engine.pipeline_parse(data)
	defer engine.cleanup_Render_Pipeline(&back)
	testing.expect(t, ok, "a pipeline parses back")
	testing.expect_value(t, len(back.steps), 9)
	testing.expect_value(t, back.next_id, p.next_id)
	bias, has := back.steps[1].settings.(json.Object)["bias"]
	testing.expect(t, has && bias.(json.Float) == 0.01, "the settings JSON round-trips")

	clone := engine.pipeline_clone(back)
	defer engine.cleanup_Render_Pipeline(&clone)
	testing.expect_value(t, len(clone.steps), 9)
	engine.pipeline_remove_slot(&clone, engine.MAIN_SLOT)
	testing.expect_value(t, len(clone.steps), 2) // only the frame lane remains
	testing.expect_value(t, len(clone.slots), 0)
}

// The generated registrations keep their reads and writes after the
// registration proc returns: the slices point at file-scope arrays, not at
// the proc's stack (a stack literal read back as garbage and crashed the
// pipeline window). And the declarations parsed as written.
@(test)
test_render_steps_registered_declarations :: proc(t: ^testing.T) {
	// Overwrite the stack the registration ran on, so a dangling slice reads junk.
	junk: [4096]u8
	for &b, i in junk do b = u8(i * 7)
	seen_read := false
	for n in engine.render_steps() {
		testing.expect(t, n.pkg != "", "every step names its package")
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
	testing.expect(t, seen_read, "some step declares a read")
	_ = junk

	opaque := engine.render_step_find("scene_opaque")
	testing.expect(t, opaque != nil, "the engine's scene_opaque is registered")
	if opaque != nil {
		testing.expect_value(t, len(opaque.writes), 1)
		testing.expect_value(t, opaque.writes[0].name, engine.HDR_TARGET)
		testing.expect_value(t, opaque.writes[0].format, gfx.Target_Format.HDR)
		testing.expect(t, opaque.writes[0].final, "the scene image is the first final")
	}
	cascades := engine.render_step_find("shadow_cascades")
	testing.expect(t, cascades != nil && !cascades.frame && cascades.writes[0].px == i32(engine.SHADOW_CASCADE_ATLAS_SIZE) && cascades.writes[0].format == .Depth)
	testing.expect(t, cascades != nil && cascades.settings_tid == typeid_of(engine.Shadow_Settings), "shadow_cascades declares its settings")
	atlas := engine.render_step_find("shadow_atlas")
	testing.expect(t, atlas != nil && atlas.frame && atlas.writes[0].px == i32(engine.SHADOW_ATLAS_SIZE) && atlas.writes[0].format == .Depth)
	testing.expect(t, atlas != nil && atlas.settings_tid == typeid_of(engine.Shadow_Atlas_Settings), "shadow_atlas declares its settings")
}

// A read declared with a trailing `?` registers without the `?` and marked
// optional, parallel to the reads: scene_opaque works without shadows and
// ambient occlusion, scene_taa without motion vectors. render_reads answers
// for the declared names.
@(test)
test_render_steps_optional_reads :: proc(t: ^testing.T) {
	for n in engine.render_steps() {
		if n.optional != nil do testing.expectf(t, len(n.optional) == len(n.reads), "%s: one optional flag per read", n.name)
		for r in n.reads do testing.expectf(t, r[len(r) - 1] != '?', "%s registers %q with its `?`", n.name, r)
	}
	optional :: proc(name, read: string) -> (declared, opt: bool) {
		s := engine.render_step_find(name)
		if s == nil do return
		for r, i in s.reads do if r == read do return true, engine.render_step_read_optional(s, i)
		return
	}
	expect_optional :: proc(t: ^testing.T, name, read: string, want: bool, loc := #caller_location) {
		declared, opt := optional(name, read)
		testing.expectf(t, declared, "%s reads %s", name, read, loc = loc)
		testing.expectf(t, opt == want, "%s's read of %s optional = %v", name, read, want, loc = loc)
	}
	expect_optional(t, "scene_opaque", engine.SCENE_INPUT, false)
	expect_optional(t, "scene_opaque", engine.SHADOW_TARGET, true)
	expect_optional(t, "scene_opaque", engine.SHADOW_ATLAS_TARGET, true)
	expect_optional(t, "scene_opaque", engine.SSAO_TARGET, true)
	expect_optional(t, "scene_opaque", engine.SSR_TARGET, true)
	expect_optional(t, "scene_taa", engine.MOTION_TARGET, true)
	expect_optional(t, "scene_taa", engine.HDR_TARGET, false)

	ctx := engine.Render_Ctx{step = engine.render_step_find("scene_opaque")}
	testing.expect(t, engine.render_reads(&ctx, engine.SSAO_TARGET), "scene_opaque reads ssao")
	testing.expect(t, engine.render_reads(&ctx, engine.SSR_TARGET), "scene_opaque reads ssr")
	testing.expect(t, !engine.render_reads(&ctx, engine.MOTION_TARGET), "scene_opaque does not read motion")
}

// The Render Pipeline window shows what a step takes from another as a read:
// with scene_ssao before scene_opaque, ssao is read by scene_opaque, not a
// scratch target. Without scene_ssao the optional read is no read at all:
// no ssao row, nothing reported missing.
@(test)
test_render_pipeline_window_optional_reads :: proc(t: ^testing.T) {
	saved := rpv._rp.doc
	defer rpv._rp.doc = saved
	find :: proc(m: rpv._Model, name: string) -> ^rpv._Resource {
		for &r in m.res do if r.name == name do return &r
		return nil
	}

	with: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&with)
	engine.pipeline_add_slot(&with, engine.MAIN_SLOT)
	engine.pipeline_add_step(&with, "scene_ssao", engine.MAIN_SLOT)
	engine.pipeline_add_step(&with, "scene_opaque", engine.MAIN_SLOT)
	rpv._rp.doc = &with
	m := rpv._rp_model(engine.MAIN_SLOT)
	ssao := find(m, engine.SSAO_TARGET)
	testing.expect(t, ssao != nil, "scene_ssao writes ssao")
	if ssao != nil {
		testing.expect(t, !ssao.scratch, "scene_opaque reads ssao: not scratch")
		testing.expect(t, !ssao.missing, "ssao has its writer")
	}

	without: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&without)
	engine.pipeline_add_slot(&without, engine.MAIN_SLOT)
	engine.pipeline_add_step(&without, "scene_opaque", engine.MAIN_SLOT)
	rpv._rp.doc = &without
	m = rpv._rp_model(engine.MAIN_SLOT)
	testing.expect(t, find(m, engine.SSAO_TARGET) == nil, "no ssao row without its writer")
	testing.expect(t, find(m, engine.SHADOW_TARGET) == nil, "no shadow row without its writer")
	for r in m.res do testing.expectf(t, !r.missing, "%s reported missing", r.name)
}

// The step the Render Pipeline window looks at: the one shown in the scene
// view, else the selected one. The captured run draws without the TAA jitter
// while it lies before the resolve (render_pipeline_run).
@(test)
test_render_inspect_looks_at :: proc(t: ^testing.T) {
	defer engine.render_inspect_request("", 0)
	defer engine.render_inspect_show(0, "")
	before := []engine.Pipeline_Instance{{id = 5}, {id = 6}}
	engine.render_inspect_request(engine.MAIN_SLOT, 6)
	testing.expect(t, engine._inspect_looks_at(before), "the selected step is before the resolve")
	engine.render_inspect_request(engine.MAIN_SLOT, 7)
	testing.expect(t, !engine._inspect_looks_at(before), "a step after the resolve is not")
	engine.render_inspect_request(engine.MAIN_SLOT, 0)
	testing.expect(t, !engine._inspect_looks_at(before), "nothing selected")
	engine.render_inspect_show(5, engine.HDR_TARGET)
	engine.render_inspect_request(engine.MAIN_SLOT, 7)
	testing.expect(t, engine._inspect_looks_at(before), "the step shown in the scene view counts over the selection")
}

// --- Volumes ---------------------------------------------------------------------

@(private = "file")
Blend_Settings :: struct {
	amount: f32,
	on:     bool,
	mode:   enum u8 {A, B, C},
	color:  [4]f32,
	nested: struct {
		radius: f32,
		count:  int,
	},
}

// Numbers, alone, in arrays and in nested structs, interpolate. Switches,
// enums and integers snap to the source once the weight reaches a half.
@(test)
test_settings_blend :: proc(t: ^testing.T) {
	dst := Blend_Settings{amount = 0, on = false, mode = .A, color = {0, 0, 0, 1}, nested = {radius = 1, count = 2}}
	src := Blend_Settings{amount = 1, on = true, mode = .C, color = {1, 0.5, 0, 1}, nested = {radius = 3, count = 8}}
	quarter := dst
	engine.settings_blend(typeid_of(Blend_Settings), &quarter, &src, 0.25)
	testing.expect_value(t, quarter.amount, f32(0.25))
	testing.expect_value(t, quarter.color, [4]f32{0.25, 0.125, 0, 1})
	testing.expect_value(t, quarter.nested.radius, f32(1.5))
	testing.expect(t, !quarter.on && quarter.mode == .A && quarter.nested.count == 2, "below a half the switches stay")
	half := dst
	engine.settings_blend(typeid_of(Blend_Settings), &half, &src, 0.5)
	testing.expect(t, half.on && half.mode == .C && half.nested.count == 8, "at a half the switches take the source")
	testing.expect_value(t, half.amount, f32(0.5))
}

// A global volume applies its weight anywhere. A local one applies it inside
// its box (the transform's scale scales the box), fades over the blend
// distance outside, and is gone beyond it. Without a blend distance it
// switches at the edge.
@(test)
test_volume_weight :: proc(t: ^testing.T) {
	tw := engine.Transform_World{position = {10, 0, 0}, rotation = {0, 0, 0, 1}, scale = {2, 1, 1}}
	v := engine.Volume{size = {4, 4, 4}, blend_distance = 2, weight = 0.8}
	testing.expect_value(t, engine.volume_weight(&v, tw, {10, 0, 0}), f32(0.8))
	testing.expect_value(t, engine.volume_weight(&v, tw, {13.9, 0, 0}), f32(0.8)) // half size 2 x scale 2 = 4
	testing.expectf(t, abs(engine.volume_weight(&v, tw, {15, 0, 0}) - 0.4) < 1e-5, "halfway through the blend: %v", engine.volume_weight(&v, tw, {15, 0, 0}))
	testing.expect_value(t, engine.volume_weight(&v, tw, {17, 0, 0}), f32(0))
	testing.expect_value(t, engine.volume_weight(&v, tw, {10, 2.5, 0}), f32(0.6)) // y: half size 2, 0.5 into the blend
	v.blend_distance = 0
	testing.expect_value(t, engine.volume_weight(&v, tw, {10, 2.5, 0}), f32(0))
	v.global = true
	testing.expect_value(t, engine.volume_weight(&v, tw, {100, 100, 100}), f32(0.8))
}

// A step runs with the pipeline's settings blended toward a volume's
// override when the view's camera is inside the volume: the tint step sees
// amount 2 from the pipeline, a volume at full weight sets 0.5 (its default),
// and the step reports what it got.
@(test)
test_render_pipeline_volume_overrides_settings :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_pipeline_volume.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)
	_register_test_steps()
	_calls = make([dynamic]string)
	defer delete(_calls)

	p: engine.Render_Pipeline
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	tint := engine.pipeline_add_step(&p, "t_tint", engine.MAIN_SLOT)
	engine.pipeline_find_step(&p, tint).settings = _settings_json("amount", 2)
	engine.render_pipeline_preview({}, p)
	engine.cleanup_Render_Pipeline(&p)
	defer engine.render_pipeline_preview({}, {})

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	vol_tH := engine.transform_new("Volume", root)
	_, vol := engine.transform_get_or_add_comp(vol_tH, engine.Volume)
	vol.enabled = true
	vol.size = {4, 4, 4}
	vol.weight = 1
	append(&vol.overrides, engine.Volume_Override{step = strings.clone("t_tint"), settings = strings.clone(`{"amount": 0.5}`)})

	ctx: engine.Render_Ctx
	ctx.view.cam_pos = {0, 0, 0} // inside
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	ctx.view.cam_pos = {50, 0, 0} // outside
	testing.expect(t, engine.render_pipeline_run(engine.MAIN_SLOT, &ctx))
	testing.expect_value(t, len(_calls), 2)
	if len(_calls) == 2 {
		testing.expect_value(t, _calls[0], "tint:default") // the volume's 0.5
		testing.expect_value(t, _calls[1], "tint:set")     // the pipeline's 2
	}
}

// The Render Pipeline window on a pipeline's shared document: muting a step
// previews it under the window's draw allocator, which is not the one the
// preview string lives on. The preview frees that string with its own
// allocator, so the mute neither crashes nor leaks.
@(test)
test_render_pipeline_window_mute_previews :: proc(t: ^testing.T) {
	dir :: "moonhug/tests/fixtures/_rp_window_tmp"
	path :: dir + "/Muted.renderpipeline"
	tc := new(TestCtx)
	defer free(tc)
	setup(tc)
	context.user_ptr = &tc.uc
	defer teardown(tc)
	os.make_directory(dir)
	defer {
		_remove_tree(dir)
		_remove_tree(engine.library_dir())
	}
	p: engine.Render_Pipeline
	defer engine.cleanup_Render_Pipeline(&p)
	engine.pipeline_add_slot(&p, engine.MAIN_SLOT)
	engine.pipeline_add_step(&p, "scene_opaque", engine.MAIN_SLOT)
	testing.expect(t, engine.pipeline_save_file(&p, path), "the pipeline file is written")
	asset_pipeline.asset_pipeline_init()
	engine.asset_db_init(dir)
	defer engine.asset_db_shutdown()
	defer inspector.asset_docs_shutdown()
	guid, gok := engine.asset_db_get_guid(path)
	testing.expect(t, gok, "the pipeline is in the asset db")
	if !gok do return
	defer {
		rpv._rp.guid = {}
		rpv._rp.seen = nil
		rpv._rp.doc = nil
		rpv._rp.asset = nil
	}

	rpv._rp_open_guid(engine.Asset_GUID(guid))
	testing.expect(t, rpv._rp_fetch(), "the window looks up the shared document")
	// In a debug editor the draw runs on the document allocator, the editor's
	// tracking allocator over the default heap. A tracking allocator of the
	// same shape plays that part, and must see no free of memory it never
	// gave out.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.default_allocator())
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		rpv._rp.doc.steps[0].muted = true
		rpv._rp_touch("Mute")
		rpv._rp_preview()
	}
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect(t, rpv._rp.doc.steps[0].muted, "the step stays muted")
}
