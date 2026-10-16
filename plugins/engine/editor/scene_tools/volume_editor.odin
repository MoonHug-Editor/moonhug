package scene_tools

// The Volume component in the editor (plugins/engine/component_Volume.odin):
// its box in the scene view, and an inspector that edits each override
// through the step's own settings drawer, the one the Render Pipeline
// window uses, so a volume's block looks and edits like the pipeline's.

import "base:runtime"
import "core:encoding/json"
import "core:hash"
import "core:slice"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/handles"
import "moonhug:editor/inspector"
import "moonhug:editor/widgets"
import "moonhug:libs/gizmos"
import "moonhug:libs/log"
import "moonhug:packages/engine"
import undo "moonhug:packages/engine/editor/undo"

VOLUME_GIZMO_COLOR :: [4]f32{0.55, 0.85, 1, 0.6}

// The box, and the blend distance's outer box around it (world units, so
// drawn without the transform's scale).
@(on_draw_gizmos={component=Volume})
volume_gizmos :: proc(v: ^engine.Volume, ctx: handles.Gizmo_Context) {
	if .In_Selection not_in ctx.state || v.global do return
	tH := engine.Transform_Handle(v.owner)
	gizmos.with_color(VOLUME_GIZMO_COLOR)
	gizmos.in_local_space(tH)
	gizmos.wire_box({}, v.size)
	if v.blend_distance > 0 {
		gizmos.with_color({VOLUME_GIZMO_COLOR.r, VOLUME_GIZMO_COLOR.g, VOLUME_GIZMO_COLOR.b, 0.25})
		gizmos.in_local_space(tH, use_scale = false)
		gizmos.wire_box({}, v.size * engine.transform_world(tH).scale + 2 * v.blend_distance)
	}
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
volume_inspector_install :: proc() {
	inspector.add_component_wrapper(typeid_of(engine.Volume), _volume_inspector)
}

@(phase={key=engine.Phase.EditorShutdown, order=1, mode=Editor})
volume_inspector_shutdown :: proc() {
	for _, &b in _buffers do delete(b.buf)
	delete(_buffers)
	_buffers = nil
}

// The typed buffer an override is edited in, per volume and override index,
// refilled when its JSON changed under it (an undo, another editor).
@(private = "file")
_Buffer_Key :: struct {
	owner: engine.Transform_Handle,
	index: int,
}

@(private = "file")
_Buffer :: struct {
	hash: u64,
	buf:  []u8,
}

@(private = "file")
_buffers: map[_Buffer_Key]_Buffer

@(private = "file")
_volume_inspector :: proc(ctx: ^inspector.Component_Ctx) {
	inspector.draw(ctx)
	v := cast(^engine.Volume)ctx.ptr
	owned, _ := engine.transform_get_comp(v.owner, engine.Volume)
	whole := [?]undo.Edit_Target{undo.edit_target_whole(owned.handle)}

	im.SeparatorText("Overrides")
	for i := 0; i < len(v.overrides); i += 1 {
		o := &v.overrides[i]
		im.PushIDInt(i32(i))
		defer im.PopID()
		step := engine.render_step_find(o.step)
		open := im.CollapsingHeader(strings.clone_to_cstring(o.step, context.temp_allocator), {.DefaultOpen})
		im.SameLine(im.GetContentRegionAvail().x - 60)
		if im.SmallButton("Remove") {
			sess := undo.edit_session_begin(whole[:], "Remove Volume Override")
			delete(o.step)
			delete(o.settings)
			ordered_remove(&v.overrides, i)
			undo.edit_session_end(&sess)
			inspector.mark_inspector_changed()
			i -= 1
			continue
		}
		if !open do continue
		if step == nil {
			im.TextDisabled("Not installed: no linked plugin declares this step")
			continue
		}
		if step.settings_size == 0 {
			im.TextDisabled("This step has no settings")
			continue
		}
		buf := _buffer(v, i, step)
		before := slice.clone(buf, context.temp_allocator)
		// The rows record nothing: the session records the whole component.
		undo.push_owner(undo.Inspector_Owner{kind = .None})
		inspector.draw_inspector(any{raw_data(buf), step.settings_tid})
		undo.pop_owner()
		if runtime.memory_compare(raw_data(before), raw_data(buf), len(buf)) != 0 {
			bytes, merr := json.marshal(any{raw_data(buf), step.settings_tid}, {spec = .JSON, use_enum_names = true}, context.temp_allocator)
			if merr != nil {
				log.errorf("[Render] a Volume's settings of %s do not marshal: %v", step.name, merr)
				continue
			}
			sess := undo.edit_session_begin(whole[:], "Edit Volume Override")
			delete(o.settings)
			o.settings = strings.clone(string(bytes))
			undo.edit_session_end(&sess)
			inspector.mark_inspector_changed()
			_buffers[{v.owner, i}] = {hash = hash.fnv64a(bytes), buf = buf}
		}
	}

	// A step with settings the volume does not override yet.
	if im.Button("Add Override") do im.OpenPopup("##volume_add")
	widgets.tooltip("A render step whose settings this volume changes: its whole block, starting from the step's defaults")
	if im.BeginPopup("##volume_add") {
		any_step := false
		for &step in engine.render_steps() {
			if step.settings_size == 0 do continue
			taken := false
			for o in v.overrides do if o.step == step.name do taken = true
			if taken do continue
			any_step = true
			if im.MenuItem(strings.clone_to_cstring(step.name, context.temp_allocator)) {
				sess := undo.edit_session_begin(whole[:], "Add Volume Override")
				append(&v.overrides, engine.Volume_Override{step = strings.clone(step.name), settings = strings.clone("")})
				undo.edit_session_end(&sess)
				inspector.mark_inspector_changed()
			}
		}
		if !any_step do im.TextDisabled("Every step with settings is overridden")
		im.EndPopup()
	}
}

// The typed buffer for override `index`, filled from its JSON when that
// changed since the last fill.
@(private = "file")
_buffer :: proc(v: ^engine.Volume, index: int, step: ^engine.Render_Step) -> []u8 {
	context.allocator = runtime.default_allocator()
	o := &v.overrides[index]
	key := _Buffer_Key{v.owner, index}
	h := hash.fnv64a(transmute([]u8)o.settings)
	b, found := &_buffers[key]
	if found && b.hash == h && len(b.buf) == step.settings_size do return b.buf
	if !found {
		_buffers[key] = {}
		b = &_buffers[key]
	}
	if len(b.buf) != step.settings_size {
		delete(b.buf)
		b.buf = make([]u8, step.settings_size)
	}
	b.hash = h
	if !engine.render_step_settings_parse(step, o.settings, b.buf) {
		log.warningf("[Render] a Volume's override of %q is not its settings: defaults shown", step.name)
	}
	return b.buf
}
