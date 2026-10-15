package previews

// Inspector Preview pane drawers for the engine's visual assets — textures
// (the real texture, sharp at any size), models, scenes and materials (their
// thumbnail, scaled). A selected SUB-asset previews itself: a sprite slice
// shows its crop, a mesh part its rendered thumb — resolved through the same
// subassets registry + thumbnail cache the project window uses. Audio's
// waveform preview registers from its own package the same way.

import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import engine "moonhug:packages/engine"
import gfx "moonhug:libs/gfx"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"
import "moonhug:editor/thumbnails"

// The inspector's previews and the thumbnail renderers, after inspector.init.
@(provider_install)
_register_asset_previews :: proc() {
	register_thumbnail_renderers()
	for ext in ([]string{".png", ".jpg", ".jpeg", ".bmp"}) {
		inspector.mapAssetPreview[ext] = _preview_texture
	}
	for ext in ([]string{".glb", ".gltf"}) {
		inspector.mapAssetPreview[ext] = _preview_model
	}
	inspector.mapAssetPreview[".scene"] = _preview_scene
	inspector.mapAssetPreview[".mat"] = _preview_thumb
	// Asset content changes: the live previews redraw (_pv_needs_draw).
	engine.asset_db_add_evict_hook(_pv_asset_changed)
	engine.asset_pipeline_add_reimport_hook(_pv_asset_reimported)
}

// Before the editor's own shutdown (order 0), which tears down the scene
// manager the preview world's scene belongs to.
@(phase={key=engine.Phase.EditorShutdown, order=-1, mode=Editor})
_shutdown_asset_previews :: proc() {
	asset_previews_shutdown()
	preview_world_shutdown()
}

asset_previews_shutdown :: proc() {
	// Just drop the handle: the instance lives in the preview world, and
	// preview_world_shutdown destroys that world with everything in it.
	// Reaching into the world here would rebuild it after it was torn down.
	_scene_pv_root = {}
	_scene_pv_guid = {}
	// Same for the clip rig's transforms.
	_clip_pv.rig = {}
	if _mesh_pv_rt != nil {
		gfx.rt_destroy(_mesh_pv_rt)
		_mesh_pv_rt = nil
	}
	_pv_drawn = {}
}

// The active selection's sub-asset for `path`, when one is selected. The
// editor root answers inspector.selected_sub from the project selection.
_preview_selected_sub :: proc(path: string) -> (subassets.Sub_Asset, bool) {
	if inspector.selected_sub == nil do return {}, false
	id := inspector.selected_sub(path)
	if id == 0 do return {}, false
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	provider, ok := subassets.find(ext)
	if !ok do return {}, false
	for s in provider.list(path, context.temp_allocator) {
		if s.id == id do return s, true
	}
	return {}, false
}

_preview_draw_region :: proc(id: rawptr, uv0, uv1: [2]f32, w, h: f32) {
	avail := im.GetContentRegionAvail()
	if avail.x < 16 || avail.y < 16 do return
	scale := min(avail.x / max(w, 1), avail.y / max(h, 1))
	dw, dh := w * scale, h * scale
	pos := im.GetCursorScreenPos()
	p0 := im.Vec2{pos.x + (avail.x - dw) * 0.5, pos.y + (avail.y - dh) * 0.5}
	im.DrawList_AddImage(im.GetWindowDrawList(),
		im.TextureRef{_TexID = im.TextureID(uintptr(id))},
		p0, im.Vec2{p0.x + dw, p0.y + dh},
		im.Vec2{uv0.x, uv0.y}, im.Vec2{uv1.x, uv1.y})
	im.Dummy(avail)
}

// Textures draw the RESIDENT texture, not the 128px thumb — sharp at pane
// size. A selected slice draws its crop.
_preview_texture :: proc(path: string) {
	guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	tex, tok := engine.texture_load(engine.Asset_GUID(guid))
	if !tok do return

	uv0, uv1 := [2]f32{0, 0}, [2]f32{1, 1}
	w, h := f32(tex.width), f32(tex.height)
	if s, sok := _preview_selected_sub(path); sok {
		if rect, rok := engine.texture_sprite_rect(tex, s.id); rok {
			uv0 = {rect.rect.x / w, rect.rect.y / h}
			uv1 = {(rect.rect.x + rect.rect.z) / w, (rect.rect.y + rect.rect.w) / h}
			w, h = rect.rect.z, rect.rect.w
		}
	}
	_preview_draw_region(gfx.texture_imgui_id(tex.gfx), uv0, uv1, w, h)
}

// --- When a live preview redraws -----------------------------------------------
// The live previews (model, scene, clip) render into _mesh_pv_rt only when
// their picture would change: another asset, part or clip, a new pane size,
// orbit or zoom input, a clip's time, or a change to asset content. An idle
// preview shows the picture it rendered last, so a selected scene costs
// nothing per frame however large it is. Asset content changes arrive through
// the asset database's evict hook (a changed or removed file), the pipeline's
// reimport hook and the material cache's version (live material edits).

@(private = "file")
_Pv_Kind :: enum u8 {
	None,
	Model,
	Scene,
	Clip,
}

// Everything a live preview's picture depends on.
@(private = "file")
_Pv_Key :: struct {
	kind:             _Pv_Kind,
	guid:             engine.Asset_GUID,
	sub:              i64,    // the model's part, the clip's id
	size:             [2]i32, // the pane, the target's size
	time:             f32,    // a clip's
	yaw, pitch, zoom: f32,
	content:          u64,    // _pv_content
	materials:        u64,    // engine.material_cache_version
}

// What _mesh_pv_rt shows.
@(private = "file") _pv_drawn: _Pv_Key

// Asset files changed or reimported, counted by the hooks below.
@(private = "file") _pv_content: u64

// Whether the preview `key` describes has to render now: true once per change
// of anything its picture depends on, which it then counts as drawn.
@(private = "file")
_pv_needs_draw :: proc(key: _Pv_Key) -> bool {
	k := key
	k.yaw, k.pitch, k.zoom = _mesh_pv_yaw, _mesh_pv_pitch, _mesh_pv_zoom
	k.content = _pv_content
	k.materials = engine.material_cache_version
	if k == _pv_drawn do return false
	_pv_drawn = k
	return true
}

// The asset database's evict hook: a file changed or went away. The previewed
// scene's own file respawns its instance.
@(private = "file")
_pv_asset_changed :: proc(path: string) {
	_pv_content += 1
	if guid, ok := engine.asset_db_get_guid(path); ok && engine.Asset_GUID(guid) == _scene_pv_guid {
		_scene_pv_stale = true
	}
}

// The asset pipeline's reimport hook: an artifact changed (a model, a
// texture, a shader).
@(private = "file")
_pv_asset_reimported :: proc(guid: engine.Asset_GUID) {
	_pv_content += 1
	if guid == _scene_pv_guid do _scene_pv_stale = true
}

// --- Live mesh preview --------------------------------------------------------
// The mesh preview: the model (or the selected part) rendered into an RT at
// pane size when its picture changes, orbited by dragging, zoomed by wheel. No scene spawn —
// one Draw_Mesh command straight through render_execute (white unlit, the
// filter carries no materials).

_mesh_pv_rt: ^gfx.Render_Target
_mesh_pv_yaw: f32 = 0.8
_mesh_pv_pitch: f32 = 0.5
_mesh_pv_zoom: f32 = 1

_preview_model :: proc(path: string) {
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)

	part := i32(0)
	if s, sok := _preview_selected_sub(path); sok {
		if idx, iok := engine.mesh_part_index(guid, s.id); iok {
			part = idx + 1
		} else if _, cok := engine.mesh_clip_index(guid, s.id); cok {
			_preview_clip(path, guid, s.id)
			return
		}
	}
	mesh, mok := engine.mesh_load(guid, part)
	if !mok {
		im.TextDisabled("mesh not loadable")
		return
	}

	avail := im.GetContentRegionAvail()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))

	if _pv_needs_draw({kind = .Model, guid = guid, sub = i64(part), size = {i32(avail.x), i32(avail.y)}}) {
		center := (mesh.aabb_min + mesh.aabb_max) * 0.5
		radius := max(linalg.length(mesh.aabb_max - mesh.aabb_min) * 0.5, 0.01)
		rv, forward := _pv_view(center, radius, avail)

		// Lit, with a camera headlight — the mesh draws
		// directly, bypassing material resolution (no material = unlit white).
		gfx.set_lights([]gfx.Light{{
			kind      = .Directional,
			direction = forward,
			color     = {1, 1, 1},
			intensity = 1,
		}}, 0.35)
		gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0.16, 0.16, 0.18, 1})
		gfx.set_view_proj(rv.view_proj, rv.cam_pos)
		for sub in mesh.submeshes {
			gfx.draw_mesh(mesh.gpu, nil, linalg.MATRIX4F32_IDENTITY, {1, 1, 1, 1}, "lit", sub.first_index, sub.index_count, nil, nil)
		}
		gfx.pass_end()
		gfx.set_lights_default() // the headlight must not leak into later passes
	}

	_pv_image_orbit(_mesh_pv_rt, avail)
}

// The orbit camera at the shared preview angles, framing (center, radius).
// Returns the view and the camera's forward (the headlight direction).
_pv_view :: proc(center: [3]f32, radius: f32, avail: im.Vec2) -> (engine.Render_View, [3]f32) {
	cp := math.cos(_mesh_pv_pitch)
	forward := [3]f32{-math.cos(_mesh_pv_yaw) * cp, -math.sin(_mesh_pv_pitch), -math.sin(_mesh_pv_yaw) * cp}
	fov := math.to_radians(f32(35))
	dist := radius / math.sin(fov * 0.5) * 1.1 * _mesh_pv_zoom
	eye := center - forward * dist
	view := linalg.matrix4_look_at_f32(eye, center, [3]f32{0, 1, 0})
	proj := gfx.matrix4_perspective_z01(fov, avail.x / avail.y, max(dist - radius * 2, 0.01), dist + radius * 2)
	return engine.render_view_make(view, proj, avail.x, avail.y, _THUMB_LAYER, .Preview), forward
}

// The RT drawn over an InvisibleButton (the button captures the drag even
// when the cursor leaves the pane mid-gesture), orbit + zoom input.
_pv_image_orbit :: proc(rt: ^gfx.Render_Target, avail: im.Vec2) {
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##orbit_preview", avail)
	im.DrawList_AddImage(im.GetWindowDrawList(),
		im.TextureRef{_TexID = im.TextureID(uintptr(gfx.rt_imgui_id(rt)))},
		pos, im.Vec2{pos.x + avail.x, pos.y + avail.y})
	if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		delta := im.GetIO().MouseDelta
		_mesh_pv_yaw += delta.x * 0.01
		_mesh_pv_pitch = clamp(_mesh_pv_pitch + delta.y * 0.01, -1.45, 1.45)
	}
	if im.IsItemHovered() {
		if wheel := im.GetIO().MouseWheel; wheel != 0 {
			_mesh_pv_zoom = clamp(_mesh_pv_zoom * math.pow(f32(1.12), -wheel), 0.3, 4)
		}
	}
}

// Prefab (.scene) preview: the prefab instantiated and orbited live, rendered
// when its picture changes (_pv_needs_draw). Content goes on the reserved
// preview layer and the view masks to it, so the open scene's content never
// bleeds in.
// The scene instance behind the preview, kept alive between frames. Spawning
// is a full deserialize of the scene file and every object it creates, so
// doing it per frame pegged a core on a 35-object scene. Exactly one lives at
// a time: the preview world is rendered whole, so a leftover instance from a
// previous selection would be drawn into the next one's picture.
@(private = "file") _scene_pv_guid: engine.Asset_GUID
@(private = "file") _scene_pv_root: engine.Transform_Handle
@(private = "file") _scene_pv_center: [3]f32
@(private = "file") _scene_pv_radius: f32
// The previewed scene's file changed since it was spawned (_pv_asset_changed).
@(private = "file") _scene_pv_stale: bool

// Frees the instance. Must run inside preview_world_begin/end — its
// transforms live in the preview world's pools.
@(private = "file")
_scene_pv_release :: proc() {
	if _scene_pv_root == {} do return
	engine.transform_destroy(_scene_pv_root)
	_scene_pv_root = {}
	_scene_pv_guid = {}
}

_preview_scene :: proc(path: string) {
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)

	avail := im.GetContentRegionAvail()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))

	// Respawn only when the selection moved to another scene or the scene's
	// file changed. Bounds come from the same pass, so the tree is walked
	// once per instance rather than once per frame.
	respawn := guid != _scene_pv_guid || _scene_pv_root == {} || _scene_pv_stale
	draw := _pv_needs_draw({kind = .Scene, guid = guid, size = {i32(avail.x), i32(avail.y)}})
	if respawn || draw {
		prev := preview_world_begin()
		defer preview_world_end(prev)

		if respawn {
			_scene_pv_release()
			_scene_pv_stale = false
			spawned := engine.scene_instantiate_guid(guid, preview_world_root())
			if spawned == {} {
				im.TextDisabled("scene not loadable")
				return
			}
			_thumb_set_layer(spawned)
			bmin, bmax, bok := _thumb_bounds(spawned)
			if !bok {
				engine.transform_destroy(spawned)
				return
			}
			_scene_pv_guid = guid
			_scene_pv_root = spawned
			_scene_pv_center = (bmin + bmax) * 0.5
			_scene_pv_radius = max(linalg.length(bmax - bmin) * 0.5, 0.01)
		}

		rv, _ := _pv_view(_scene_pv_center, _scene_pv_radius, avail)

		cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
		engine.render_collect_commands(rv, &cmds)
		gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0.16, 0.16, 0.18, 1})
		engine.render_execute(rv, cmds[:])
		gfx.pass_end()
	}

	_pv_image_orbit(_mesh_pv_rt, avail)
}

// A clip inside a model: the model's skeleton posed by the clip, scrubbed by a
// slider or playing, orbitable like the other 3D previews. The rig lives in
// the preview world between frames (see _preview_scene for why one instance
// at a time) and is rebuilt when the selection moves to another clip.
@(private = "file") _clip_pv: struct {
	owner:   engine.Asset_GUID,
	id:      engine.Local_ID,
	rig:     Model_Clip_Rig,
	time:    f32,
	playing: bool,
	center:  [3]f32,
	radius:  f32,
}

@(private = "file")
_clip_pv_release :: proc() {
	if _clip_pv.rig.root != {} do model_clip_rig_destroy(&_clip_pv.rig)
	_clip_pv.owner = {}
	_clip_pv.id = 0
}

@(private = "file")
_preview_clip :: proc(path: string, owner: engine.Asset_GUID, clip_id: engine.Local_ID) {
	avail := im.GetContentRegionAvail()
	controls_h := im.GetFrameHeightWithSpacing()
	if avail.x < 32 || avail.y < 32 + controls_h do return

	prev := preview_world_begin()
	defer preview_world_end(prev)

	if owner != _clip_pv.owner || clip_id != _clip_pv.id || _clip_pv.rig.root == {} {
		_clip_pv_release()
		if subassets.clip_sampler == nil {
			im.TextDisabled("Clips preview with the animation plugin installed.")
			return
		}
		rig, ok := model_clip_rig_build(path, owner, clip_id, preview_world_root())
		if !ok {
			im.TextDisabled("clip not loadable")
			return
		}
		_clip_pv.rig = rig
		_clip_pv.owner = owner
		_clip_pv.id = clip_id
		_clip_pv.time = 0
		_clip_pv.playing = true
		// Bounds from the rest pose, once. A walking character would
		// otherwise pull the camera along with every step.
		_thumb_set_layer(rig.root)
		bmin, bmax, bok := _thumb_bounds(rig.root)
		if !bok {
			bmin, bmax = {-1, -1, -1}, {1, 1, 1}
		}
		_clip_pv.center = (bmin + bmax) * 0.5
		_clip_pv.radius = max(linalg.length(bmax - bmin) * 0.5, 0.01)
	}
	rig := &_clip_pv.rig

	// Transport: play toggle and a scrub over the clip's length.
	if im.Button(_clip_pv.playing ? icons.ICON_MD_PAUSE : icons.ICON_MD_PLAY_ARROW) do _clip_pv.playing = !_clip_pv.playing
	widgets.tooltip(_clip_pv.playing ? "Pause" : "Play")
	im.SameLine()
	im.SetNextItemWidth(im.GetContentRegionAvail().x)
	if im.SliderFloat("##clip_time", &_clip_pv.time, 0, rig.length, "%.2f s") do _clip_pv.playing = false
	if _clip_pv.playing {
		_clip_pv.time += im.GetIO().DeltaTime
		if _clip_pv.time > rig.length do _clip_pv.time -= rig.length
	}

	avail = im.GetContentRegionAvail()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))
	// Posed and rendered when the picture changes: every frame while it
	// plays, once per scrub while it is paused.
	if _pv_needs_draw({kind = .Clip, guid = owner, sub = i64(clip_id), size = {i32(avail.x), i32(avail.y)}, time = _clip_pv.time}) {
		model_clip_rig_pose(rig, _clip_pv.time)
		rv, forward := _pv_view(_clip_pv.center, _clip_pv.radius, avail)
		cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
		engine.render_collect_commands(rv, &cmds)
		// A headlight from the camera, the same one the model preview uses: the
		// preview world has no lights of its own, and unlit reads as flat white.
		gfx.set_lights([]gfx.Light{{kind = .Directional, direction = forward, color = {1, 1, 1}, intensity = 1}}, 0.35)
		gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0.16, 0.16, 0.18, 1})
		engine.render_execute(rv, cmds[:])
		gfx.pass_end()
		gfx.set_lights_default() // the headlight must not leak into later passes
	}
	_pv_image_orbit(_mesh_pv_rt, avail)
}

// Scenes and materials draw their thumbnail scaled.
_preview_thumb :: proc(path: string) {
	if s, sok := _preview_selected_sub(path); sok {
		if tid, uv0, uv1, tok := thumbnails.get_sub(path, s); tok {
			w := s.size.x > 0 ? s.size.x : 1
			h := s.size.y > 0 ? s.size.y : 1
			_preview_draw_region(tid, uv0, uv1, w, h)
		}
		return
	}
	if tid, tok := thumbnails.get(path); tok {
		_preview_draw_region(tid, {0, 0}, {1, 1}, 1, 1)
	}
}
