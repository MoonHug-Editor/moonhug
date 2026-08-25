package editor

// Inspector Preview pane drawers for the engine's visual assets — textures
// (the real texture, sharp at any size), models, scenes and materials (their
// thumbnail, scaled). A selected SUB-asset previews itself: a sprite slice
// shows its crop, a mesh part its rendered thumb — resolved through the same
// subassets registry + thumbnail service the project window uses. Audio's
// waveform preview registers from its own package the same way.

import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import engine "../engine"
import gfx "../engine/gfx"
import im "moonhug:external/odin-imgui"
import "inspector"
import "subassets"

_register_asset_previews :: proc() {
	for ext in ([]string{".png", ".jpg", ".jpeg", ".bmp"}) {
		inspector.mapAssetPreview[ext] = _preview_texture
	}
	for ext in ([]string{".glb", ".gltf"}) {
		inspector.mapAssetPreview[ext] = _preview_model
	}
	inspector.mapAssetPreview[".scene"] = _preview_scene
	inspector.mapAssetPreview[".mat"] = _preview_thumb
}

_pv_scene: ^engine.Scene // scratch for prefab previews, content spawn/destroy per draw

asset_previews_shutdown :: proc() {
	if _mesh_pv_rt != nil {
		gfx.rt_destroy(_mesh_pv_rt)
		_mesh_pv_rt = nil
	}
	if _pv_scene != nil {
		engine.scene_destroy(_pv_scene)
		_pv_scene = nil
	}
}

// The active selection's sub-asset for `path`, when one is selected.
_preview_selected_sub :: proc(path: string) -> (subassets.Sub_Asset, bool) {
	entries := sel_proj_entries()
	if len(entries) == 0 do return {}, false
	active := entries[len(entries) - 1]
	if active.sub_id == 0 || active.path != path do return {}, false
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	provider, ok := subassets.find(ext)
	if !ok do return {}, false
	for s in provider.list(path, context.temp_allocator) {
		if s.id == active.sub_id do return s, true
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

// --- Live mesh preview --------------------------------------------------------
// Unity's mesh preview: the model (or the selected part) rendered LIVE into
// an RT at pane size, orbited by dragging, zoomed by wheel. No scene spawn —
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
		if idx, iok := engine.mesh_part_index(guid, s.id); iok do part = idx + 1
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

	center := (mesh.aabb_min + mesh.aabb_max) * 0.5
	radius := max(linalg.length(mesh.aabb_max - mesh.aabb_min) * 0.5, 0.01)
	rv, forward := _pv_view(center, radius, avail)

	// Lit, with a camera headlight (Unity's preview light) — the mesh draws
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
	return engine.render_view_make(view, proj, avail.x, avail.y, _THUMB_LAYER), forward
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

// Prefab (.scene) preview — Unity's: the prefab instantiated and orbited
// live. Spawn, render, destroy WITHIN this call: nothing persists into the
// frame's picking or views (the thumbnail renderer's contract). Content goes
// on the reserved preview layer and the view masks to it, so the open
// scene's content never bleeds in.
_preview_scene :: proc(path: string) {
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)

	avail := im.GetContentRegionAvail()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))

	if _pv_scene == nil {
		_pv_scene = engine.scene_new()
		engine.scene_ensure_root(_pv_scene)
	}
	root := engine.Transform_Handle(_pv_scene.root.handle)
	spawned := engine.scene_instantiate_guid(guid, root)
	if spawned == {} {
		im.TextDisabled("prefab not loadable")
		return
	}
	defer engine.transform_destroy(spawned)
	_thumb_set_layer(spawned)

	bmin, bmax, bok := _thumb_bounds(spawned)
	if !bok do return
	center := (bmin + bmax) * 0.5
	radius := max(linalg.length(bmax - bmin) * 0.5, 0.01)
	rv, _ := _pv_view(center, radius, avail)

	cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(rv, &cmds)
	gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0.16, 0.16, 0.18, 1})
	engine.render_execute(rv, cmds[:])
	gfx.pass_end()

	_pv_image_orbit(_mesh_pv_rt, avail)
}

// Scenes and materials draw their thumbnail scaled.
_preview_thumb :: proc(path: string) {
	if s, sok := _preview_selected_sub(path); sok {
		if tid, uv0, uv1, tok := thumbnail_get_sub(path, s); tok {
			w := s.size.x > 0 ? s.size.x : 1
			h := s.size.y > 0 ? s.size.y : 1
			_preview_draw_region(tid, uv0, uv1, w, h)
		}
		return
	}
	if tid, tok := thumbnail_get(path); tok {
		_preview_draw_region(tid, {0, 0}, {1, 1}, 1, 1)
	}
}
