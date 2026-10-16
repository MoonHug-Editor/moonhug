package engine

// What the Render Pipeline window shows of a running frame
// (plugins/engine/docs/RenderPipeline.md "Inspecting a frame"): for every
// placed step, a thumbnail of each target it wrote, as it was right after
// the step ran, and the objects, meshes, materials and textures it drew.
// Optionally one step's output replaces the scene view's image.
//
// Nothing happens unless the window asked this frame or the one before
// (render_inspect_request), so a closed window costs nothing. The window
// names one slot. The scene view's run of that slot is captured, or the
// first camera's when the scene view renders another slot. The frame lane is
// captured whenever its steps run.
//
// The capture copies each target a step took (render_target) right after
// the step, so an in-place target like "hdr" gets one thumbnail per step that
// wrote it, each showing its state at that point of the frame.

import "base:runtime"
import "core:strings"
import gfx "moonhug:libs/gfx"

// The thumbnails' width in pixels, the height follows the target's aspect.
INSPECT_THUMB_W :: 256

// What one placed step did in the captured run.
Inspect_Step :: struct {
	ran:       bool,                  // the step ran this capture (not muted, not a frame step already run)
	taken:     [dynamic]string,       // the targets it took (render_target), in order, owned
	objects:   [dynamic]Transform_Handle, // what it drew, each once
	meshes:    [dynamic]Asset_GUID,
	materials: [dynamic]Asset_GUID,
	textures:  [dynamic]Asset_GUID,   // quads' own textures (a material's are found from the material)
	// Taken color targets the step drew only the depth of (the depth
	// prepass), owned: shown as their depth from a perspective camera. A
	// Depth target always shows its depth, read as orthographic.
	depth_views: [dynamic]string,
}

@(private = "file")
_inspect: struct {
	slot:       string, // owned, the slot the window shows
	requested:  u64,    // gfx.frame_index + 1 of the last request
	selected:   i32,    // the step the window selected (entry id), 0 = none
	scene_done: u64,    // gfx.frame_index + 1 when the scene view's run was captured
	pool:       gfx.Target_Pool, // thumbnails, "<id>/<target>"
	steps:      map[i32]Inspect_Step,
	recording:  ^Inspect_Step,   // the step running in a captured run
	show_id:    i32,             // 0 = off: the step whose output the scene view shows
	show_name:  string,          // owned, the target of it shown
	shown:      u64,             // gfx.frame_index + 1 of the last copy of the shown output
}

// The window calls this every frame it draws: captures happen for `slot`
// this frame and the next. `selected` is the step the window shows the
// images of (entry id, 0 = none).
render_inspect_request :: proc(slot: string, selected: i32 = 0) {
	context.allocator = runtime.default_allocator()
	if _inspect.slot != slot {
		delete(_inspect.slot)
		_inspect.slot = strings.clone(slot)
	}
	_inspect.requested = gfx.frame_index + 1
	_inspect.selected = selected
}

render_inspect_active :: proc() -> bool {
	return _inspect.requested != 0 && _inspect.requested + 2 >= gfx.frame_index + 1
}

// What the placed step `id` did in the last capture, nil when it has not run
// in one.
render_inspect_step :: proc(id: i32) -> ^Inspect_Step {
	return &_inspect.steps[id] or_else nil
}

// The thumbnail of `target` as step `id` left it, nil when the step did not
// take that target in the last capture.
render_inspect_thumb :: proc(id: i32, target: string) -> ^gfx.Render_Target {
	return gfx.pool_find(&_inspect.pool, _thumb_key(id, target))
}

// Shows step `id`'s `target` in the scene view instead of its final image.
// id 0 turns it off.
render_inspect_show :: proc(id: i32, target: string) {
	context.allocator = runtime.default_allocator()
	_inspect.show_id = id
	delete(_inspect.show_name)
	_inspect.show_name = id != 0 ? strings.clone(target) : ""
}

// The step and target the scene view shows, and whether it did last frame
// (false when that step did not take the target).
render_inspect_showing :: proc() -> (id: i32, target: string, shown: bool) {
	return _inspect.show_id, _inspect.show_name, _inspect.shown != 0 && _inspect.shown + 1 >= gfx.frame_index + 1
}

// --- The run's side, called by render_pipeline_run --------------------------

// Whether this run of `slot` is the one captured: the scene view's always,
// a camera's when the scene view has not been captured this frame.
_inspect_lane_begins :: proc(slot: string, ctx: ^Render_Ctx) -> bool {
	if !render_inspect_active() || slot != _inspect.slot do return false
	if ctx.scene_view {
		_inspect.scene_done = gfx.frame_index + 1
		return true
	}
	return _inspect.scene_done != gfx.frame_index + 1
}

// Before a step of a captured run: forget what it did last time and start
// recording.
_inspect_step_begins :: proc(id: i32) {
	context.allocator = runtime.default_allocator()
	n, ok := &_inspect.steps[id]
	if !ok {
		_inspect.steps[id] = {}
		n = &_inspect.steps[id]
	}
	_inspect_step_clear(n)
	n.ran = true
	_inspect.recording = n
}

// Whether the step the window looks at (the one shown in the scene view, else
// the selected one) is among `steps`: the captured run holds the camera
// steady while it lies before the TAA resolve, since its images are drawn
// through the jittered camera and would move up to half a pixel each frame.
_inspect_looks_at :: proc(steps: []Pipeline_Instance) -> bool {
	id := _inspect.show_id != 0 ? _inspect.show_id : _inspect.selected
	if id == 0 do return false
	for inst in steps do if inst.id == id do return true
	return false
}

// After it: one thumbnail per target it took, and the full-size copy the
// scene view shows when this is the shown step.
_inspect_step_ends :: proc(id: i32, pool: ^gfx.Target_Pool) {
	context.allocator = runtime.default_allocator()
	n := _inspect.recording
	_inspect.recording = nil
	if n == nil do return
	for name in n.taken {
		src := gfx.pool_find(pool, name)
		if src == nil do continue
		perspective := false
		for v in n.depth_views do if v == name do perspective = true
		depth := perspective || src.format == .Depth
		// Display thumbnails: imgui shows their bytes as they are.
		h := max(i32(f32(INSPECT_THUMB_W) * f32(src.height) / f32(max(src.width, 1))), 1)
		dst := gfx.pool_target(&_inspect.pool, _thumb_key(id, name), INSPECT_THUMB_W, h, .Display)
		if depth {
			_inspect_draw_depth(dst, src, perspective)
		} else {
			gfx.display_blit(dst, gfx.rt_color_texture(src))
		}
		if id == _inspect.show_id && name == _inspect.show_name {
			if depth {
				full := gfx.pool_target(&_inspect.pool, _SHOW_KEY, src.width, src.height, .LDR)
				_inspect_draw_depth(full, src, perspective)
			} else {
				full := gfx.pool_target(&_inspect.pool, _SHOW_KEY, src.width, src.height, src.format)
				gfx.rt_copy(full, src)
			}
			_inspect.shown = gfx.frame_index + 1
		}
	}
}

// `src`'s depth as grey into `dst` (gfx.draw_depth_view).
@(private = "file")
_inspect_draw_depth :: proc(dst, src: ^gfx.Render_Target, perspective: bool) {
	gfx.pass_begin_target(dst, [4]f32{0, 0, 0, 1})
	gfx.draw_depth_view(gfx.rt_depth_texture(src), perspective)
	gfx.pass_end()
}

// Called by a step that drew only the depth of a color target it took (the
// depth prepass), so its thumbnail shows that depth rather than the color.
_inspect_depth_view :: proc(name: string) {
	n := _inspect.recording
	if n == nil do return
	context.allocator = runtime.default_allocator() // cross-frame state
	for v in n.depth_views do if v == name do return
	append(&n.depth_views, strings.clone(name))
}

// A muted step in a captured run: shown as not run.
_inspect_step_skipped :: proc(id: i32) {
	if n, ok := &_inspect.steps[id]; ok {
		_inspect_step_clear(n)
	}
}

// At the end of the scene view's run: the shown step's output over the
// view's image.
_inspect_lane_ends :: proc(ctx: ^Render_Ctx) {
	if !ctx.scene_view || _inspect.show_id == 0 || ctx.target == nil do return
	src := gfx.pool_find(&_inspect.pool, _SHOW_KEY)
	if src == nil || _inspect.shown != gfx.frame_index + 1 do return
	gfx.display_blit(ctx.target, gfx.rt_color_texture(src))
}

// Called when a step takes a target (render_step_registry.odin).
_inspect_taken :: proc(name: string) {
	n := _inspect.recording
	if n == nil do return
	for t in n.taken do if t == name do return
	append(&n.taken, strings.clone(name, runtime.default_allocator()))
}

// Called for every command a step draws (render_execute, render_execute_depth).
_inspect_draw :: proc(cmd: Render_Command) {
	n := _inspect.recording
	if n == nil do return
	context.allocator = runtime.default_allocator()
	add_owner(&n.objects, cmd.owner)
	switch d in cmd.variant {
	case Draw_Mesh:
		add_guid(&n.meshes, d.mesh)
		for m in d.materials do add_guid(&n.materials, m)
	case Draw_Quad:
		add_guid(&n.textures, d.texture)
		add_guid(&n.materials, d.material)
	}
	add_owner :: proc(list: ^[dynamic]Transform_Handle, h: Transform_Handle) {
		for x in list do if x == h do return
		append(list, h)
	}
	add_guid :: proc(list: ^[dynamic]Asset_GUID, g: Asset_GUID) {
		if g == {} do return
		for x in list do if x == g do return
		append(list, g)
	}
}

_render_inspect_shutdown :: proc() {
	context.allocator = runtime.default_allocator()
	for _, &n in _inspect.steps do _inspect_step_clear(&n)
	for _, &n in _inspect.steps {
		delete(n.taken)
		delete(n.objects)
		delete(n.meshes)
		delete(n.materials)
		delete(n.textures)
		delete(n.depth_views)
	}
	delete(_inspect.steps)
	gfx.pool_destroy(&_inspect.pool)
	delete(_inspect.slot)
	delete(_inspect.show_name)
	_inspect = {}
}

@(private = "file")
_SHOW_KEY :: "__shown"

@(private = "file")
_thumb_key :: proc(id: i32, target: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, int(id))
	strings.write_byte(&b, '/')
	strings.write_string(&b, target)
	return strings.to_string(b)
}

@(private = "file")
_inspect_step_clear :: proc(n: ^Inspect_Step) {
	for t in n.taken do delete(t, runtime.default_allocator())
	clear(&n.taken)
	for v in n.depth_views do delete(v, runtime.default_allocator())
	clear(&n.depth_views)
	clear(&n.objects)
	clear(&n.meshes)
	clear(&n.materials)
	clear(&n.textures)
	n.ran = false
}
