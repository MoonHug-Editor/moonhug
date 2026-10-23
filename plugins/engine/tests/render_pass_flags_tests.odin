package engine_tests

// A renderer's pass flags (MeshRenderer.cast_shadows, reflections) pick the
// views that collect it, and a Light's masks reach what lights and shadows
// read (plugins/engine/docs/Layers.md).

import "core:math/linalg"
import "core:testing"
import "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"

@(test)
test_mesh_collector_honours_pass_flags :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_render_pass_flags.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	guid := engine.Asset_GUID{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9}
	key := engine.Mesh_Key{guid, 0}
	_mesh_cache_put(key, engine.Mesh{guid = guid, aabb_min = {-0.5, -0.5, -0.5}, aabb_max = {0.5, 0.5, 0.5}})
	defer _mesh_cache_drop(key)

	root := engine.Transform_Handle(tc_mem.scene.root.handle)
	place :: proc(tc: ^TestCtx, root: engine.Transform_Handle, name: string, guid: engine.Asset_GUID, casting: engine.Shadow_Casting, refl: engine.Reflection_Visibility, layer: u32 = 1) -> engine.Transform_Handle {
		tH := engine.transform_new(name, root)
		if tr := engine.pool_get(&tc.world.transforms, engine.Handle(tH)); tr != nil do tr.render_layer = layer
		_, mf := engine.transform_get_or_add_comp(tH, engine.MeshFilter)
		mf.mesh.guid = guid
		_, mr := engine.transform_get_or_add_comp(tH, engine.MeshRenderer)
		mr.enabled = true
		mr.cast_shadows = casting
		mr.reflections = refl
		return tH
	}
	on := place(tc_mem, root, "On", guid, .On, .Visible, layer = 0b100)
	off := place(tc_mem, root, "Off", guid, .Off, .Visible)
	two := place(tc_mem, root, "Double", guid, .Double_Sided, .Visible)
	only := place(tc_mem, root, "Only", guid, .Shadows_Only, .Visible)
	hidden := place(tc_mem, root, "Hidden", guid, .On, .Hidden)

	Seen :: struct {
		owner:        engine.Transform_Handle,
		layers:       u32,
		double_sided: bool,
	}
	collect :: proc(pass: engine.View_Pass) -> map[engine.Transform_Handle]Seen {
		view := engine.render_view_make(linalg.MATRIX4F32_IDENTITY, linalg.MATRIX4F32_IDENTITY, 1, 1, ~u32(0))
		view.pass = pass
		commands := make([dynamic]engine.Render_Command, 0, 8, context.temp_allocator)
		engine.render_collect_commands(view, &commands)
		out := make(map[engine.Transform_Handle]Seen, context.temp_allocator)
		for c in commands {
			if d, is_mesh := c.variant.(engine.Draw_Mesh); is_mesh do out[c.owner] = {c.owner, d.layers, d.double_sided}
		}
		return out
	}

	color := collect(.Color)
	testing.expect_value(t, len(color), 4)
	testing.expect(t, on in color && off in color && two in color && hidden in color, "a colour view draws every mesh but the shadows-only one")
	testing.expect(t, !(only in color), "a colour view leaves out a shadows-only mesh")
	testing.expect_value(t, color[on].layers, u32(0b100))
	testing.expect(t, !color[two].double_sided, "a double-sided caster draws as its materials say outside the shadow maps")

	shadow := collect(.Shadow)
	testing.expect_value(t, len(shadow), 4)
	testing.expect(t, on in shadow && two in shadow && only in shadow && hidden in shadow, "a shadow view takes every caster, the shadows-only one too")
	testing.expect(t, !(off in shadow), "a shadow view leaves out a mesh that casts no shadows")
	testing.expect(t, shadow[two].double_sided, "a double-sided caster draws with no face culling into the shadow maps")
	testing.expect(t, !shadow[on].double_sided, "an ordinary caster keeps its materials' culling")

	probe := collect(.Probe)
	testing.expect_value(t, len(probe), 3)
	testing.expect(t, on in probe && off in probe && two in probe, "a probe capture draws the visible meshes")
	testing.expect(t, !(hidden in probe), "a probe capture leaves out a mesh hidden from reflections")
	testing.expect(t, !(only in probe), "a probe capture leaves out a shadows-only mesh")
}

@(test)
test_light_masks_reach_gfx :: proc(t: ^testing.T) {
	tc_mem := new(TestCtx)
	defer free(tc_mem)
	setup(tc_mem, "moonhug/tests/fixtures/_test_light_masks.scene")
	context.user_ptr = &tc_mem.uc
	defer teardown(tc_mem)

	tH := engine.transform_new("Lamp", engine.Transform_Handle(tc_mem.scene.root.handle))
	_, l := engine.transform_get_or_add_comp(tH, engine.Light)
	testing.expect(t, l != nil, "Light should be added")
	if l == nil do return
	testing.expect_value(t, l.culling_mask, ~u32(0))
	testing.expect_value(t, l.shadow_caster_mask, ~u32(0))
	l.enabled = true
	l.culling_mask = 0b101

	buf: [gfx.MAX_LIGHTS]gfx.Light
	n, _ := engine.scene_collect_lights(buf[:])
	testing.expect_value(t, n, 1)
	if n < 1 do return
	testing.expect_value(t, buf[0].culling_mask, u32(0b101))

	// set_lights packs the mask's bits into the light the shader reads.
	gfx.set_lights(buf[:n], 0.35)
	defer {
		gfx._pass.light = nil
		gfx._pass.light_count = 0
	}
	testing.expect_value(t, transmute(u32)gfx._pass.light_list[0].params.w, u32(0b101))
}
