package editor

// Asset thumbnails for the project view's grid mode. GPU-resident cache keyed
// by guid, invalidated by the asset db's file stamp — thumbnails regenerate
// per session on demand (no disk cache yet; that needs GPU readback).
//
// Generation is budgeted: the project view REQUESTS a thumbnail for each
// visible cell (thumbnail_get), misses queue, and thumbnails_tick renders a
// few per frame. The tick runs at the top of the frame, BEFORE any view draws:
// scene previews spawn real content into a scratch scene (never registered
// with the scene manager, so no view lists it), render it through the normal
// collect/execute pipeline into a small RT with a reserved render layer, and
// destroy it again — nothing survives into the frame's visible rendering.
//
// Supported: image files (the texture drawn aspect-fit), .mat (a quad drawn
// with the material's shader/block), .scene (the instantiated prefab framed by
// its bounds). Everything else keeps its type icon.

import "core:encoding/uuid"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import engine "../engine"
import gfx "../engine/gfx"

_THUMB_SIZE :: 128
_THUMB_JOBS_PER_FRAME :: 2
// Reserved render layer for preview content, so the thumbnail view draws ONLY
// it — the open scene's content (layer 1) never bleeds into a preview.
_THUMB_LAYER :: u32(1) << 31

_Thumb :: struct {
	tex:   ^gfx.Texture, // nil = generation produced nothing, keep the icon
	mtime: i64,
}

@(private = "file") _thumbs: map[engine.Asset_GUID]_Thumb
@(private = "file") _thumb_queue: [dynamic]engine.Asset_GUID
@(private = "file") _thumb_queued: map[engine.Asset_GUID]bool
@(private = "file") _thumb_rt: ^gfx.Render_Target
@(private = "file") _thumb_scene: ^engine.Scene

_thumb_supported :: proc(path: string) -> bool {
	switch filepath.ext(path) {
	case ".png", ".jpg", ".jpeg", ".bmp", ".tga", ".gif", ".scene", ".mat":
		return true
	}
	return false
}

// The cached thumbnail texture for an asset, as an imgui texture id. A miss
// (or stale stamp) queues generation and returns false — the caller draws the
// type icon this frame. While regenerating, the previous texture keeps showing.
thumbnail_get :: proc(path: string) -> (id: rawptr, ok: bool) {
	if !_thumb_supported(path) do return nil, false
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return nil, false
	guid := engine.Asset_GUID(raw_guid)
	stamp, sok := engine.asset_db_get_stamp(path)
	if !sok do return nil, false
	mtime := stamp.mtime._nsec

	th, has := _thumbs[guid]
	if !has || th.mtime != mtime {
		if !(guid in _thumb_queued) {
			_thumb_queued[guid] = true
			append(&_thumb_queue, guid)
		}
	}
	if has && th.tex != nil {
		return gfx.texture_imgui_id(th.tex), true
	}
	return nil, false
}

// Budgeted generation, called once per frame before any view draws (the frame
// command buffer must be live, no pass active).
thumbnails_tick :: proc() {
	for _ in 0 ..< _THUMB_JOBS_PER_FRAME {
		if len(_thumb_queue) == 0 do break
		guid := _thumb_queue[0]
		ordered_remove(&_thumb_queue, 0)
		delete_key(&_thumb_queued, guid)

		path, pok := engine.asset_db_get_path(uuid.Identifier(guid))
		if !pok do continue // deleted since the request
		stamp, sok := engine.asset_db_get_stamp(path)
		if !sok do continue

		if _thumb_rt == nil do _thumb_rt = gfx.rt_create(_THUMB_SIZE, _THUMB_SIZE)

		tex := _thumb_render(guid, path)
		if prev, has := _thumbs[guid]; has && prev.tex != nil {
			gfx.texture_destroy(prev.tex)
		}
		_thumbs[guid] = _Thumb{tex = tex, mtime = stamp.mtime._nsec}
	}
}

thumbnails_shutdown :: proc() {
	for _, th in _thumbs {
		if th.tex != nil do gfx.texture_destroy(th.tex)
	}
	delete(_thumbs)
	_thumbs = nil
	delete(_thumb_queue)
	_thumb_queue = nil
	delete(_thumb_queued)
	_thumb_queued = nil
	if _thumb_rt != nil {
		gfx.rt_destroy(_thumb_rt)
		_thumb_rt = nil
	}
	if _thumb_scene != nil {
		engine.scene_destroy(_thumb_scene)
		_thumb_scene = nil
	}
}

@(private = "file")
_thumb_render :: proc(guid: engine.Asset_GUID, path: string) -> ^gfx.Texture {
	switch filepath.ext(path) {
	case ".scene":
		return _thumb_render_scene(guid)
	case ".mat":
		return _thumb_render_material(guid)
	case:
		return _thumb_render_image(guid)
	}
}

// stb rows are top-down: v=1 on the bottom corners (matches render_execute).
@(private = "file")
_THUMB_UVS :: [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// The texture drawn aspect-fit on a transparent background. The quad's corners
// are in clip space directly (identity view-proj): bl, br, tr, tl.
@(private = "file")
_thumb_render_image :: proc(guid: engine.Asset_GUID) -> ^gfx.Texture {
	t2d, ok := engine.texture_load(guid)
	if !ok || t2d.gfx == nil do return nil
	sx, sy: f32 = 1, 1
	if t2d.width > t2d.height {
		sy = f32(t2d.height) / f32(t2d.width)
	} else if t2d.height > 0 {
		sx = f32(t2d.width) / f32(t2d.height)
	}
	corners := [4][3]f32{{-sx, -sy, 0}, {sx, -sy, 0}, {sx, sy, 0}, {-sx, sy, 0}}

	gfx.pass_begin_target(_thumb_rt, [4]f32{0, 0, 0, 0})
	gfx.set_view_proj(linalg.MATRIX4F32_IDENTITY)
	gfx.draw_quad(corners, _THUMB_UVS, {1, 1, 1, 1}, t2d.gfx)
	gfx.pass_end()
	return gfx.rt_snapshot(_thumb_rt)
}

// A full-cell quad drawn with the material's shader, block and textures — a
// flat swatch (no preview mesh exists yet).
@(private = "file")
_thumb_render_material :: proc(guid: engine.Asset_GUID) -> ^gfx.Texture {
	shader, tex, color, data, extra := engine.material_resolve_draw(guid)
	corners := [4][3]f32{{-0.9, -0.9, 0}, {0.9, -0.9, 0}, {0.9, 0.9, 0}, {-0.9, 0.9, 0}}

	gfx.pass_begin_target(_thumb_rt, [4]f32{0.16, 0.16, 0.18, 1})
	gfx.set_view_proj(linalg.MATRIX4F32_IDENTITY)
	gfx.draw_quad(corners, _THUMB_UVS, color, tex, shader, data, {0, 0, 1}, extra)
	gfx.pass_end()
	return gfx.rt_snapshot(_thumb_rt)
}

// Instantiates the prefab into the scratch scene, frames its bounds with a
// perspective camera (front-on when the content is flat — sprite scenes),
// renders through the normal pipeline, and destroys the content again.
@(private = "file")
_thumb_render_scene :: proc(guid: engine.Asset_GUID) -> ^gfx.Texture {
	if _thumb_scene == nil {
		_thumb_scene = engine.scene_new()
		engine.scene_ensure_root(_thumb_scene)
	}
	root := engine.Transform_Handle(_thumb_scene.root.handle)
	spawned := engine.scene_instantiate_guid(guid, root)
	if spawned == {} do return nil
	defer engine.transform_destroy(spawned)
	_thumb_set_layer(spawned)

	bmin, bmax, bok := _thumb_bounds(spawned)
	if !bok do return nil
	center := (bmin + bmax) * 0.5
	radius := max(linalg.length(bmax - bmin) * 0.5, 0.01)

	// Flat content (2D scenes) reads best front-on; anything with depth gets
	// the standard 3/4 view.
	forward := [3]f32{0, 0, -1}
	up := [3]f32{0, 1, 0}
	if bmax.z - bmin.z > radius * 0.1 {
		forward = linalg.normalize([3]f32{-1, -0.7, -1})
	}
	fov := math.to_radians(f32(35))
	dist := radius / math.sin(fov * 0.5) * 1.05
	eye := center - forward * dist
	view := linalg.matrix4_look_at_f32(eye, center, up)
	proj := gfx.matrix4_perspective_z01(fov, 1, max(dist - radius * 2, 0.01), dist + radius * 2)
	rv := engine.render_view_make(view, proj, _THUMB_SIZE, _THUMB_SIZE, _THUMB_LAYER)

	cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(rv, &cmds)
	if len(cmds) == 0 do return nil // nothing drawable — keep the icon

	gfx.pass_begin_target(_thumb_rt, [4]f32{0.16, 0.16, 0.18, 1})
	engine.render_execute(rv, cmds[:])
	gfx.pass_end()
	return gfx.rt_snapshot(_thumb_rt)
}

@(private = "file")
_thumb_set_layer :: proc(tH: engine.Transform_Handle) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	t.render_layer = _THUMB_LAYER
	for child in t.children {
		_thumb_set_layer(engine.Transform_Handle(child.handle))
	}
}

// World bounds of a subtree: mesh AABBs and sprite corners where present,
// transform positions otherwise.
@(private = "file")
_thumb_bounds :: proc(tH: engine.Transform_Handle) -> (bmin, bmax: [3]f32, ok: bool) {
	bmin = {max(f32), max(f32), max(f32)}
	bmax = {min(f32), min(f32), min(f32)}
	_thumb_bounds_walk(tH, &bmin, &bmax, &ok)
	return
}

@(private = "file")
_thumb_bounds_walk :: proc(tH: engine.Transform_Handle, bmin, bmax: ^[3]f32, any_point: ^bool) {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	tw := engine.transform_world(tH)

	grow :: proc(bmin, bmax: ^[3]f32, any_point: ^bool, p: [3]f32) {
		bmin^ = linalg.min(bmin^, p)
		bmax^ = linalg.max(bmax^, p)
		any_point^ = true
	}

	if _, mf := engine.transform_get_comp(tH, engine.MeshFilter); mf != nil && mf.mesh != {} {
		if mesh, mok := engine.mesh_load(mf.mesh, mf.part); mok {
			model := engine.trs_matrix(tw.position, tw.rotation, tw.scale)
			for i in 0 ..< 8 {
				c := [4]f32{
					i & 1 == 0 ? mesh.aabb_min.x : mesh.aabb_max.x,
					i & 2 == 0 ? mesh.aabb_min.y : mesh.aabb_max.y,
					i & 4 == 0 ? mesh.aabb_min.z : mesh.aabb_max.z,
					1,
				}
				p := model * c
				grow(bmin, bmax, any_point, p.xyz)
			}
		}
	}
	if _, sr := engine.transform_get_comp(tH, engine.SpriteRenderer); sr != nil && sr.texture != {} {
		if tex, tok := engine.texture_load(sr.texture); tok {
			for p in engine.sprite_world_corners(tw, tex) {
				grow(bmin, bmax, any_point, p)
			}
		}
	}
	grow(bmin, bmax, any_point, tw.position)

	for child in t.children {
		_thumb_bounds_walk(engine.Transform_Handle(child.handle), bmin, bmax, any_point)
	}
}
