package particles_editor

// Editor-only half of the particles package. The ParticleSystem inspector is
// a full REPLACEMENT wrapper shaped like Unity's Shuriken: the main module's
// fields on top, then collapsible module groups — Emission (with the bursts
// list), Shape, the over-lifetime modules with ENABLE toggles (on = seeded
// values, off = cleared, matching the runtime's zero-is-off conventions),
// Renderer. Every field drives the inspector's own row machinery
// (field_edit_row / the enum edit protocol), so undo sessions, multiedit
// peers and prefab overrides work exactly like generic rows. Structural
// edits (burst add/remove, module toggles) bracket with structural_edit so
// they land in undo as whole-component steps. Never compiled into the app.

import "core:fmt"
import im "moonhug:external/odin-imgui"
import "moonhug:engine"
import "moonhug:editor/inspector"
import "moonhug:editor/undo"
import particles "moonhug:packages/particles"

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
particles_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(particles.ParticleSystem), _particle_system_inspector)
}

// One field through the generic row machinery (drawer + undo edit session +
// peers + override recording), like the generic struct loop drives it.
_ps_field :: proc(ps: ^particles.ParticleSystem, ptr: rawptr, tid: typeid, label: cstring, path: string) {
	im.PushIDStr(label, nil)
	offset := uintptr(ptr) - uintptr(ps)
	drawer := inspector.resolve_property_drawer(tid)
	finished := inspector.field_edit_row(ptr, tid, offset, path, drawer, label)
	inspector.record_nested_override(ptr, tid, path, finished)
	im.PopID()
}

// Enums land from a combo popup — the generic loop's enum protocol.
_ps_enum :: proc(ps: ^particles.ParticleSystem, ptr: rawptr, tid: typeid, label: cstring, path: string) {
	im.PushIDStr(label, nil)
	offset := uintptr(ptr) - uintptr(ps)
	inspector.multi_probe_field(ptr, tid, offset)
	inspector.field_edit_begin(ptr, tid, offset, path)
	inspector.draw_inspector_enum(ptr, tid, label)
	inspector.multi_clear_mixed()
	changed := inspector.is_changed_flag_set()
	if changed do inspector.field_edit_apply_to_peers(ptr, tid, offset)
	inspector.record_nested_override(ptr, tid, path, changed)
	if changed || !im.IsItemActive() do inspector.field_edit_end()
	im.PopID()
}

// Color fields keep their picker (the [4]f32 drawer is four drags).
_ps_color :: proc(ps: ^particles.ParticleSystem, ptr: ^[4]f32, label: cstring, path: string) {
	im.PushIDStr(label, nil)
	offset := uintptr(ptr) - uintptr(ps)
	inspector.field_edit_begin(ptr, typeid_of([4]f32), offset, path)
	changed := im.ColorEdit4(inspector.field_row(label), ptr, {.AlphaBar})
	if changed {
		inspector.mark_inspector_changed()
		inspector.field_edit_apply_to_peers(ptr, typeid_of([4]f32), offset)
	}
	inspector.record_nested_override(ptr, typeid_of([4]f32), path, inspector.field_commit_state_of(changed) != .None)
	if changed || !im.IsItemActive() do inspector.field_edit_end()
	im.PopID()
}

// A Unity module header: enable checkbox + collapsing header on one row.
// nil toggle = an always-on module. Returns whether the body draws.
_module :: proc(label: cstring, enabled: ^bool = nil) -> (open: bool, toggled: bool) {
	if enabled != nil {
		toggled = im.Checkbox(fmt.ctprintf("##%s_on", label), enabled)
		im.SameLine(0, 4)
	}
	open = im.CollapsingHeader(label, {.DefaultOpen})
	return
}

// A module toggle mutates the component's data directly (the toggle IS the
// data — zero/empty means off at runtime). Bracket the mutation so it lands
// in undo, and record the touched fields as prefab overrides.
_toggle_begin :: proc() -> undo.Edit_Session {
	return inspector.structural_edit_begin("Toggle Module")
}

_toggle_end :: proc(sess: ^undo.Edit_Session) {
	inspector.structural_edit_end(sess)
}

// --- Bursts list ---------------------------------------------------------------
//
// Burst drags share one whole-component undo session: it opens when a burst
// widget activates and closes when it deactivates (only one widget is ever
// active). Bursts don't propagate to multiedit peers — Unity doesn't
// multiedit particle systems either.

@(private = "file") _burst_sess: undo.Edit_Session
@(private = "file") _burst_editing: bool

_burst_widget :: proc(ps: ^particles.ParticleSystem, changed: bool) {
	if im.IsItemActivated() && !_burst_editing {
		_burst_sess = inspector.structural_edit_begin("Edit Burst")
		_burst_editing = true
	}
	if changed do inspector.mark_inspector_changed()
	if im.IsItemDeactivated() && _burst_editing {
		inspector.structural_edit_end(&_burst_sess)
		_burst_editing = false
		inspector.record_nested_override(&ps.bursts, typeid_of([dynamic]particles.Burst), "bursts", true)
	}
}

_bursts_rows :: proc(ps: ^particles.ParticleSystem) {
	im.SeparatorText("Bursts")
	remove_at := -1
	if len(ps.bursts) > 0 && im.BeginTable("##bursts", 7, im.TableFlags_SizingStretchProp) {
		im.TableSetupColumn("Time")
		im.TableSetupColumn("Count Min")
		im.TableSetupColumn("Count Max")
		im.TableSetupColumn("Cycles")
		im.TableSetupColumn("Interval")
		im.TableSetupColumn("Probability")
		im.TableSetupColumn("##del", {.WidthFixed}, 22)
		im.TableHeadersRow()
		for &b, i in ps.bursts {
			im.PushIDInt(i32(i))
			im.TableNextRow()
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragFloat("##time", &b.time, 0.05, 0, 0, "%.2f"))
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragInt("##cmin", &b.count_min, 0.25, 0, 10000))
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragInt("##cmax", &b.count_max, 0.25, 0, 10000))
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragInt("##cycles", &b.cycles, 0.25, 1, 1000))
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragFloat("##interval", &b.interval, 0.01, 0, 0, "%.2f"))
			im.TableNextColumn()
			im.SetNextItemWidth(-1)
			_burst_widget(ps, im.DragFloat("##prob", &b.probability, 0.01, 0, 1, "%.2f"))
			im.TableNextColumn()
			if im.Button("x") do remove_at = i
			im.PopID()
		}
		im.EndTable()
	}
	if remove_at >= 0 {
		sess := inspector.structural_edit_begin("Remove Burst")
		ordered_remove(&ps.bursts, remove_at)
		inspector.structural_edit_end(&sess)
		inspector.record_nested_override(&ps.bursts, typeid_of([dynamic]particles.Burst), "bursts", true)
	}
	if im.Button("Add Burst") {
		sess := inspector.structural_edit_begin("Add Burst")
		append(&ps.bursts, particles.Burst{
			count_min = 30, count_max = 30, cycles = 1, interval = 0.01, probability = 1,
		})
		inspector.structural_edit_end(&sess)
		inspector.record_nested_override(&ps.bursts, typeid_of([dynamic]particles.Burst), "bursts", true)
	}
}

_particle_system_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	ps := cast(^particles.ParticleSystem)ctx.ptr

	// Main module (Unity: always visible, no header).
	_ps_field(ps, &ps.duration, typeid_of(f32), "Duration", "duration")
	_ps_field(ps, &ps.looping, typeid_of(bool), "Looping", "looping")
	_ps_field(ps, &ps.prewarm, typeid_of(bool), "Prewarm", "prewarm")
	_ps_field(ps, &ps.start_delay, typeid_of(f32), "Start Delay", "start_delay")
	_ps_field(ps, &ps.lifetime_min, typeid_of(f32), "Lifetime Min", "lifetime_min")
	_ps_field(ps, &ps.lifetime_max, typeid_of(f32), "Lifetime Max", "lifetime_max")
	_ps_field(ps, &ps.speed_min, typeid_of(f32), "Speed Min", "speed_min")
	_ps_field(ps, &ps.speed_max, typeid_of(f32), "Speed Max", "speed_max")
	_ps_field(ps, &ps.size_min, typeid_of(f32), "Size Min", "size_min")
	_ps_field(ps, &ps.size_max, typeid_of(f32), "Size Max", "size_max")
	_ps_field(ps, &ps.rotation_min, typeid_of(f32), "Rotation Min", "rotation_min")
	_ps_field(ps, &ps.rotation_max, typeid_of(f32), "Rotation Max", "rotation_max")
	_ps_field(ps, &ps.flip_rotation, typeid_of(f32), "Flip Rotation", "flip_rotation")
	_ps_color(ps, &ps.color_a, "Color A", "color_a")
	_ps_color(ps, &ps.color_b, "Color B", "color_b")
	_ps_field(ps, &ps.gravity_modifier, typeid_of(f32), "Gravity Modifier", "gravity_modifier")
	_ps_enum(ps, &ps.sim_space, typeid_of(particles.Sim_Space), "Simulation Space", "sim_space")
	_ps_field(ps, &ps.simulation_speed, typeid_of(f32), "Simulation Speed", "simulation_speed")
	_ps_field(ps, &ps.max_particles, typeid_of(i32), "Max Particles", "max_particles")

	if open, _ := _module("Emission"); open {
		_ps_field(ps, &ps.rate, typeid_of(f32), "Rate over Time", "rate")
		_ps_field(ps, &ps.rate_over_distance, typeid_of(f32), "Rate over Distance", "rate_over_distance")
		_bursts_rows(ps)
	}

	if open, _ := _module("Shape"); open {
		_ps_enum(ps, &ps.shape, typeid_of(particles.Emit_Shape), "Shape", "shape")
		switch ps.shape {
		case .Cone:
			_ps_field(ps, &ps.shape_radius, typeid_of(f32), "Radius", "shape_radius")
			_ps_field(ps, &ps.shape_angle, typeid_of(f32), "Angle", "shape_angle")
		case .Sphere, .Hemisphere, .Circle:
			_ps_field(ps, &ps.shape_radius, typeid_of(f32), "Radius", "shape_radius")
		case .Edge:
			_ps_field(ps, &ps.shape_radius, typeid_of(f32), "Half Length", "shape_radius")
		case .Box:
			_ps_field(ps, &ps.shape_box, typeid_of([3]f32), "Box Size", "shape_box")
		case .Point:
		}
		_ps_field(ps, &ps.randomize_direction, typeid_of(f32), "Randomize Direction", "randomize_direction")
		_ps_field(ps, &ps.spherize_direction, typeid_of(f32), "Spherize Direction", "spherize_direction")
	}

	// Over-lifetime modules: the toggle IS the data — on seeds values, off
	// clears them (zero/empty = module off at runtime).
	{
		on := len(ps.velocity_x.keys) > 0 || len(ps.velocity_y.keys) > 0 || len(ps.velocity_z.keys) > 0 ||
			len(ps.orbital_x.keys) > 0 || len(ps.orbital_y.keys) > 0 || len(ps.orbital_z.keys) > 0
		open, toggled := _module("Velocity over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.velocity_x.keys)
			clear(&ps.velocity_y.keys)
			clear(&ps.velocity_z.keys)
			clear(&ps.orbital_x.keys)
			clear(&ps.orbital_y.keys)
			clear(&ps.orbital_z.keys)
			if on {
				append(&ps.velocity_x.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
				append(&ps.velocity_y.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
				append(&ps.velocity_z.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.velocity_x, typeid_of(engine.Curve), "velocity_x", true)
			inspector.record_nested_override(&ps.velocity_y, typeid_of(engine.Curve), "velocity_y", true)
			inspector.record_nested_override(&ps.velocity_z, typeid_of(engine.Curve), "velocity_z", true)
			inspector.record_nested_override(&ps.orbital_x, typeid_of(engine.Curve), "orbital_x", true)
			inspector.record_nested_override(&ps.orbital_y, typeid_of(engine.Curve), "orbital_y", true)
			inspector.record_nested_override(&ps.orbital_z, typeid_of(engine.Curve), "orbital_z", true)
		}
		if open {
			_ps_field(ps, &ps.velocity_x, typeid_of(engine.Curve), "X", "velocity_x")
			_ps_field(ps, &ps.velocity_y, typeid_of(engine.Curve), "Y", "velocity_y")
			_ps_field(ps, &ps.velocity_z, typeid_of(engine.Curve), "Z", "velocity_z")
			_ps_field(ps, &ps.orbital_x, typeid_of(engine.Curve), "Orbital X", "orbital_x")
			_ps_field(ps, &ps.orbital_y, typeid_of(engine.Curve), "Orbital Y", "orbital_y")
			_ps_field(ps, &ps.orbital_z, typeid_of(engine.Curve), "Orbital Z", "orbital_z")
		}
	}
	{
		on := ps.limit_speed > 0
		open, toggled := _module("Limit Velocity over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			ps.limit_speed = 1 if on else 0
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.limit_speed, typeid_of(f32), "limit_speed", true)
		}
		if open {
			_ps_field(ps, &ps.limit_speed, typeid_of(f32), "Speed", "limit_speed")
			_ps_field(ps, &ps.limit_dampen, typeid_of(f32), "Dampen", "limit_dampen")
		}
	}
	{
		on := len(ps.force_x.keys) > 0 || len(ps.force_y.keys) > 0 || len(ps.force_z.keys) > 0
		open, toggled := _module("Force over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.force_x.keys)
			clear(&ps.force_y.keys)
			clear(&ps.force_z.keys)
			if on {
				append(&ps.force_x.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
				append(&ps.force_y.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
				append(&ps.force_z.keys, engine.Curve_Key{t = 0, value = 0}, engine.Curve_Key{t = 1, value = 0})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.force_x, typeid_of(engine.Curve), "force_x", true)
			inspector.record_nested_override(&ps.force_y, typeid_of(engine.Curve), "force_y", true)
			inspector.record_nested_override(&ps.force_z, typeid_of(engine.Curve), "force_z", true)
		}
		if open {
			_ps_field(ps, &ps.force_x, typeid_of(engine.Curve), "X", "force_x")
			_ps_field(ps, &ps.force_y, typeid_of(engine.Curve), "Y", "force_y")
			_ps_field(ps, &ps.force_z, typeid_of(engine.Curve), "Z", "force_z")
		}
	}
	{
		on := len(ps.color_over_life.keys) > 0
		open, toggled := _module("Color over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.color_over_life.keys)
			if on {
				append(&ps.color_over_life.keys, engine.Gradient_Key{t = 0, color = {1, 1, 1, 1}})
				append(&ps.color_over_life.keys, engine.Gradient_Key{t = 1, color = {1, 1, 1, 0}})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.color_over_life, typeid_of(engine.Gradient), "color_over_life", true)
		}
		if open {
			_ps_field(ps, &ps.color_over_life, typeid_of(engine.Gradient), "Color", "color_over_life")
		}
	}
	{
		on := len(ps.color_by_speed.keys) > 0
		open, toggled := _module("Color by Speed", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.color_by_speed.keys)
			ps.color_by_speed_min = 0
			ps.color_by_speed_max = 1 if on else 0
			if on {
				append(&ps.color_by_speed.keys, engine.Gradient_Key{t = 0, color = {1, 1, 1, 1}})
				append(&ps.color_by_speed.keys, engine.Gradient_Key{t = 1, color = {1, 1, 1, 1}})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.color_by_speed, typeid_of(engine.Gradient), "color_by_speed", true)
			inspector.record_nested_override(&ps.color_by_speed_min, typeid_of(f32), "color_by_speed_min", true)
			inspector.record_nested_override(&ps.color_by_speed_max, typeid_of(f32), "color_by_speed_max", true)
		}
		if open {
			_ps_field(ps, &ps.color_by_speed, typeid_of(engine.Gradient), "Color", "color_by_speed")
			_ps_field(ps, &ps.color_by_speed_min, typeid_of(f32), "Speed Min", "color_by_speed_min")
			_ps_field(ps, &ps.color_by_speed_max, typeid_of(f32), "Speed Max", "color_by_speed_max")
		}
	}
	{
		on := len(ps.size_over_life.keys) > 0
		open, toggled := _module("Size over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.size_over_life.keys)
			if on {
				append(&ps.size_over_life.keys, engine.Curve_Key{t = 0, value = 1})
				append(&ps.size_over_life.keys, engine.Curve_Key{t = 1, value = 0})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.size_over_life, typeid_of(engine.Curve), "size_over_life", true)
		}
		if open {
			_ps_field(ps, &ps.size_over_life, typeid_of(engine.Curve), "Size", "size_over_life")
		}
	}
	{
		on := len(ps.size_by_speed.keys) > 0
		open, toggled := _module("Size by Speed", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.size_by_speed.keys)
			ps.size_by_speed_min = 0
			ps.size_by_speed_max = 1 if on else 0
			if on {
				append(&ps.size_by_speed.keys, engine.Curve_Key{t = 0, value = 1}, engine.Curve_Key{t = 1, value = 1})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.size_by_speed, typeid_of(engine.Curve), "size_by_speed", true)
			inspector.record_nested_override(&ps.size_by_speed_min, typeid_of(f32), "size_by_speed_min", true)
			inspector.record_nested_override(&ps.size_by_speed_max, typeid_of(f32), "size_by_speed_max", true)
		}
		if open {
			_ps_field(ps, &ps.size_by_speed, typeid_of(engine.Curve), "Size", "size_by_speed")
			_ps_field(ps, &ps.size_by_speed_min, typeid_of(f32), "Speed Min", "size_by_speed_min")
			_ps_field(ps, &ps.size_by_speed_max, typeid_of(f32), "Speed Max", "size_by_speed_max")
		}
	}
	{
		on := ps.angular_velocity_min != 0 || ps.angular_velocity_max != 0
		open, toggled := _module("Rotation over Lifetime", &on)
		if toggled {
			sess := _toggle_begin()
			ps.angular_velocity_min = 45 if on else 0
			ps.angular_velocity_max = 45 if on else 0
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.angular_velocity_min, typeid_of(f32), "angular_velocity_min", true)
			inspector.record_nested_override(&ps.angular_velocity_max, typeid_of(f32), "angular_velocity_max", true)
		}
		if open {
			_ps_field(ps, &ps.angular_velocity_min, typeid_of(f32), "Angular Velocity Min", "angular_velocity_min")
			_ps_field(ps, &ps.angular_velocity_max, typeid_of(f32), "Angular Velocity Max", "angular_velocity_max")
		}
	}
	{
		on := len(ps.rotation_by_speed.keys) > 0
		open, toggled := _module("Rotation by Speed", &on)
		if toggled {
			sess := _toggle_begin()
			clear(&ps.rotation_by_speed.keys)
			ps.rotation_by_speed_min = 0
			ps.rotation_by_speed_max = 1 if on else 0
			if on {
				append(&ps.rotation_by_speed.keys, engine.Curve_Key{t = 0, value = 45}, engine.Curve_Key{t = 1, value = 45})
			}
			_toggle_end(&sess)
			inspector.record_nested_override(&ps.rotation_by_speed, typeid_of(engine.Curve), "rotation_by_speed", true)
			inspector.record_nested_override(&ps.rotation_by_speed_min, typeid_of(f32), "rotation_by_speed_min", true)
			inspector.record_nested_override(&ps.rotation_by_speed_max, typeid_of(f32), "rotation_by_speed_max", true)
		}
		if open {
			_ps_field(ps, &ps.rotation_by_speed, typeid_of(engine.Curve), "Angular Velocity", "rotation_by_speed")
			_ps_field(ps, &ps.rotation_by_speed_min, typeid_of(f32), "Speed Min", "rotation_by_speed_min")
			_ps_field(ps, &ps.rotation_by_speed_max, typeid_of(f32), "Speed Max", "rotation_by_speed_max")
		}
	}

	if open, _ := _module("Renderer"); open {
		if inspector.sprite_ref_row("Sprite", &ps.sprite) {
			inspector.mark_inspector_changed()
			inspector.record_nested_override(&ps.sprite, typeid_of(engine.PPtr), "sprite", true)
		}
		inspector.current_field_ext_filter = "mat"
		_ps_field(ps, &ps.material, typeid_of(engine.Asset_GUID), "Material", "material")
		inspector.current_field_ext_filter = ""
		_ps_enum(ps, &ps.render_mode, typeid_of(particles.Render_Mode), "Render Mode", "render_mode")
		if ps.render_mode == .Stretched {
			_ps_field(ps, &ps.stretch_length_scale, typeid_of(f32), "Length Scale", "stretch_length_scale")
			_ps_field(ps, &ps.stretch_speed_scale, typeid_of(f32), "Speed Scale", "stretch_speed_scale")
		}
		_ps_field(ps, &ps.sorting_layer, typeid_of(i32), "Sorting Layer", "sorting_layer")
		_ps_field(ps, &ps.order_in_layer, typeid_of(i32), "Order in Layer", "order_in_layer")
	}
}
