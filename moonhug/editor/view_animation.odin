package editor

// Animation window — the scrub-preview slice of Unity's Animation window
// (docs/PlayableGraph.md step 5): pick a clip on the selected object's
// Animation component and scrub it while the editor is stopped. Dopesheet,
// curves and keyframe editing grow here on top of this path.
//
// Preview never leaks into saved data. Each frame:
//   1. the window UI sets the scrub state (clip, time, on/off),
//   2. animation_preview_apply refreshes the binding defaults from the live
//      transforms, evaluates the clip at the scrub time and applies the pose,
//   3. the scene and game views render the posed world,
//   4. animation_preview_restore writes the defaults back.
// Outside that render window the world holds authored values, so saves, undo
// and the inspector are untouched by construction — there is no preview state
// to revert when preview ends, the target dies or its scene unloads.

import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import im "moonhug:external/odin-imgui"
import engine "../engine"

@(private = "file")
_pv: struct {
	active:  bool, // preview on: the world renders the scrubbed pose
	applied: bool, // pose applied this frame, restore pending
	owner:   engine.Transform_Handle, // the Animation component's transform
	clip:    engine.Asset_GUID,
	time:    f32,
	graph:   engine.Playable_Graph, // single clip node, root
	binding: engine.Animation_Binding,
	node:    engine.Playable_Handle,
	ready:   bool,
}

shutdown_animation_view :: proc() {
	_pv_teardown()
}

// Closing the window ends the preview (Unity behavior). Called from the main
// loop when the window toggle is off.
animation_preview_stop :: proc() {
	_pv.active = false
}

@(private = "file")
_pv_teardown :: proc() {
	if _pv.ready {
		engine.playable_graph_destroy(&_pv.graph)
		engine.animation_binding_destroy(&_pv.binding)
	}
	_pv.ready = false
	_pv.node = {}
}

// The Animation component the window targets: on the active selection or its
// nearest ancestor — Unity resolves the window's target the same way, so
// selecting a child bone keeps the window on the animated root.
@(private = "file")
_pv_target :: proc() -> (owner: engine.Transform_Handle, a: ^engine.Animation) {
	w := engine.ctx_world()
	tH := sel_scene_active()
	for engine.pool_valid(&w.transforms, engine.Handle(tH)) {
		if _, comp := engine.transform_get_comp(tH, engine.Animation); comp != nil {
			return tH, comp
		}
		t := engine.pool_get(&w.transforms, engine.Handle(tH))
		if t == nil do break
		tH = engine.Transform_Handle(t.parent.handle)
	}
	return {}, nil
}

// Every clip reachable from the component: the default clip plus the authored
// layers' clips, deduplicated, temp-allocated.
@(private = "file")
_pv_clips :: proc(a: ^engine.Animation) -> []engine.Asset_GUID {
	clips := make([dynamic]engine.Asset_GUID, context.temp_allocator)
	_pv_clips_add(&clips, a.clip)
	for &l in a.layers {
		for c in l.clips do _pv_clips_add(&clips, c)
	}
	return clips[:]
}

@(private = "file")
_pv_clips_add :: proc(clips: ^[dynamic]engine.Asset_GUID, g: engine.Asset_GUID) {
	if g == {} do return
	for c in clips^ {
		if c == g do return
	}
	append(clips, g)
}

@(private = "file")
_pv_clip_name :: proc(g: engine.Asset_GUID) -> string {
	if path, ok := engine.asset_db_get_path(uuid.Identifier(g)); ok {
		return filepath.stem(path)
	}
	return "(missing clip)"
}

draw_animation_view :: proc() {
	if !im.Begin("Animation", nil, {.NoCollapse}) {
		// Tabbed-away, not closed: the preview keeps running.
		im.End()
		return
	}
	defer im.End()

	owner, a := _pv_target()
	if a == nil {
		_pv.active = false
		im.TextDisabled("Select an object with an Animation component.")
		return
	}
	// Retarget follows selection (Unity): the old target's graph and binding
	// belong to the old owner.
	if owner != _pv.owner {
		_pv_teardown()
		_pv.owner = owner
	}

	clips := _pv_clips(a)
	if len(clips) == 0 {
		_pv.active = false
		im.TextDisabled("The Animation component has no clips.")
		return
	}
	in_list := false
	for c in clips {
		if c == _pv.clip do in_list = true
	}
	if !in_list {
		_pv_teardown()
		_pv.clip = clips[0]
		_pv.time = 0
	}

	// Preview toggle (Unity's Animation window preview button). The pop must
	// match the state at push time — the click flips _pv.active in between.
	tinted := _pv.active
	if tinted do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button("Preview") do _pv.active = !_pv.active
	if tinted do im.PopStyleColor()

	im.SameLine()
	im.SetNextItemWidth(180)
	cur := strings.clone_to_cstring(_pv_clip_name(_pv.clip), context.temp_allocator)
	if im.BeginCombo("##pv_clip", cur) {
		for c in clips {
			name := strings.clone_to_cstring(_pv_clip_name(c), context.temp_allocator)
			if im.Selectable(name, c == _pv.clip) && c != _pv.clip {
				_pv_teardown()
				_pv.clip = c
				_pv.time = 0
			}
		}
		im.EndCombo()
	}

	length := f32(0)
	if clip, ok := engine.animation_clip_load(_pv.clip); ok do length = clip.length

	im.SameLine()
	im.SetNextItemWidth(-100)
	im.BeginDisabled(length <= 0)
	if im.SliderFloat("##pv_time", &_pv.time, 0, length, "%.3f") {
		_pv.active = true // scrubbing enters preview, like Unity
	}
	im.EndDisabled()
	im.SameLine()
	im.TextUnformatted(fmt.ctprintf("/ %.3f s", length))
	_pv.time = clamp(_pv.time, 0, length)

	w := engine.ctx_world()
	if t := engine.pool_get(&w.transforms, engine.Handle(owner)); t != nil {
		im.TextDisabled("Target: %s", strings.clone_to_cstring(t.name, context.temp_allocator))
	}
}

// Apply the preview pose for this frame's scene/game render. Runs in the main
// loop after the window UI set the scrub state, right before the world renders.
animation_preview_apply :: proc() {
	if !_pv.active do return
	w := engine.ctx_world()
	if !engine.pool_valid(&w.transforms, engine.Handle(_pv.owner)) || _pv.clip == {} {
		_pv.active = false
		return
	}
	clip, ok := engine.animation_clip_load(_pv.clip)
	if !ok do return

	if !_pv.ready {
		engine.playable_graph_init(&_pv.graph)
		engine.animation_binding_init(&_pv.binding, _pv.owner)
		_pv.node = engine.playable_add(&_pv.graph, engine.Clip_Playable{clip = _pv.clip})
		_pv.graph.root = _pv.node
		_pv.ready = true
	}
	if n := engine.playable_node(&_pv.graph, _pv.node); n != nil {
		n.time = clamp(_pv.time, 0, clip.length)
	}

	engine.animation_binding_refresh_defaults(&_pv.binding)
	pose := engine.playable_graph_evaluate(&_pv.graph, &_pv.binding)
	engine.animation_pose_apply(&_pv.binding, pose)
	_pv.applied = true
}

// Restore the authored pose after the scene/game render. The world spends the
// rest of the frame — saves, undo, inspector — at authored values.
animation_preview_restore :: proc() {
	if !_pv.applied do return
	_pv.applied = false
	engine.animation_binding_write_defaults(&_pv.binding)
}
