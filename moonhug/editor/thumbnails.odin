package editor

// Asset thumbnails for the project view's grid mode. GPU-resident cache keyed
// by guid, invalidated by the asset db's file stamp, backed by a disk cache
// under library/thumbnails so thumbnails survive sessions.
//
// Generation is budgeted: the project view REQUESTS a thumbnail for each
// visible cell (thumbnail_get), misses queue, and thumbnails_tick handles a
// few per frame — a valid disk entry uploads straight to a texture, everything
// else renders. The tick runs at the top of the frame, BEFORE any view draws:
// scene previews spawn real content into a scratch scene (never registered
// with the scene manager, so no view lists it), render it through the normal
// collect/execute pipeline into a small RT with a reserved render layer, and
// destroy it again — nothing survives into the frame's visible rendering.
//
// Rendered thumbnails persist asynchronously: the readback submits one frame
// after the render (the frame command buffer must be submitted first) and the
// fence is polled, never waited on — generation costs no GPU sync stalls.
// Disk entries are guid-keyed (library/thumbnails/<xx>/<guid>.thumb, raw RGBA
// + header), so a changed asset overwrites its entry in place — the only
// stale files are deleted assets', pruned once at startup.
//
// Supported: image files (the texture drawn aspect-fit), .mat (a quad drawn
// with the material's shader/block), .scene (the instantiated prefab framed by
// its bounds). Everything else keeps its type icon.

import "core:encoding/uuid"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import engine "../engine"
import sprites "moonhug:packages/sprites"
import gfx "../engine/gfx"

_THUMB_SIZE :: 128
_THUMB_JOBS_PER_FRAME :: 2
// Reserved render layer for preview content, so the thumbnail view draws ONLY
// it — the open scene's content (layer 1) never bleeds into a preview.
_THUMB_LAYER :: u32(1) << 31

_THUMB_CACHE_DIR :: "library/thumbnails"
_THUMB_FILE_MAGIC :: u32(0x4254484D) // "MHTB"
// Bump when the render style changes — every disk entry invalidates.
_THUMB_FILE_VERSION :: u32(1)

_Thumb :: struct {
	tex:   ^gfx.Texture, // nil = generation produced nothing, keep the icon
	mtime: i64,
}

// Rendered this frame — the readback can only submit after frame_end, so it
// waits one tick.
_Thumb_Save :: struct {
	guid:  engine.Asset_GUID,
	mtime: i64,
	tex:   ^gfx.Texture,
}

_Thumb_Download :: struct {
	guid:  engine.Asset_GUID,
	mtime: i64,
	dl:    ^gfx.Texture_Download,
}

_Thumb_File_Header :: struct #packed {
	magic:   u32,
	version: u32,
	mtime:   i64,
	width:   i32,
	height:  i32,
}

@(private = "file") _thumbs: map[engine.Asset_GUID]_Thumb
@(private = "file") _thumb_queue: [dynamic]engine.Asset_GUID
@(private = "file") _thumb_queued: map[engine.Asset_GUID]bool
@(private = "file") _thumb_saves: [dynamic]_Thumb_Save
@(private = "file") _thumb_downloads: [dynamic]_Thumb_Download
@(private = "file") _thumb_pruned: bool
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
	if !_thumb_pruned {
		_thumb_pruned = true
		_thumb_disk_prune()
	}

	// Finished readbacks hit the disk, then LAST tick's renders submit theirs —
	// their frame command buffer is submitted by now, so queue order makes the
	// copy see the finished pixels.
	for i := 0; i < len(_thumb_downloads); {
		d := _thumb_downloads[i]
		if !gfx.texture_download_ready(d.dl) {
			i += 1
			continue
		}
		pixels := gfx.texture_download_take(d.dl, context.temp_allocator)
		if pixels != nil {
			_thumb_disk_write(d.guid, d.mtime, pixels)
		}
		unordered_remove(&_thumb_downloads, i)
	}
	for save in _thumb_saves {
		th, has := _thumbs[save.guid]
		if !has || th.tex != save.tex do continue // superseded before the save
		if dl := gfx.texture_download_begin(save.tex); dl != nil {
			append(&_thumb_downloads, _Thumb_Download{guid = save.guid, mtime = save.mtime, dl = dl})
		}
	}
	clear(&_thumb_saves)

	for _ in 0 ..< _THUMB_JOBS_PER_FRAME {
		if len(_thumb_queue) == 0 do break
		guid := _thumb_queue[0]
		ordered_remove(&_thumb_queue, 0)
		delete_key(&_thumb_queued, guid)

		path, pok := engine.asset_db_get_path(uuid.Identifier(guid))
		if !pok do continue // deleted since the request
		stamp, sok := engine.asset_db_get_stamp(path)
		if !sok do continue
		mtime := stamp.mtime._nsec

		tex, from_disk := _thumb_disk_load(guid, mtime)
		if !from_disk {
			if _thumb_rt == nil do _thumb_rt = gfx.rt_create(_THUMB_SIZE, _THUMB_SIZE)
			tex = _thumb_render(guid, path)
			if tex != nil {
				append(&_thumb_saves, _Thumb_Save{guid = guid, mtime = mtime, tex = tex})
			}
		}
		if prev, has := _thumbs[guid]; has && prev.tex != nil {
			gfx.texture_destroy(prev.tex)
		}
		_thumbs[guid] = _Thumb{tex = tex, mtime = mtime}
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
	// Unfinished saves just regenerate next session (at most a couple).
	for d in _thumb_downloads {
		gfx.texture_download_cancel(d.dl)
	}
	delete(_thumb_downloads)
	_thumb_downloads = nil
	delete(_thumb_saves)
	_thumb_saves = nil
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

// Fan-out by the guid's first two hex chars, Unity's Library layout.
@(private = "file")
_thumb_disk_path :: proc(guid: engine.Asset_GUID) -> string {
	id := uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
	return fmt.tprintf("%s/%s/%s.thumb", _THUMB_CACHE_DIR, id[:2], id)
}

@(private = "file")
_thumb_disk_write :: proc(guid: engine.Asset_GUID, mtime: i64, pixels: []u8) {
	os.make_directory("library")
	os.make_directory(_THUMB_CACHE_DIR)
	id := uuid.to_string(uuid.Identifier(guid), context.temp_allocator)
	os.make_directory(fmt.tprintf("%s/%s", _THUMB_CACHE_DIR, id[:2]))
	path := _thumb_disk_path(guid)

	header := _Thumb_File_Header{
		magic   = _THUMB_FILE_MAGIC,
		version = _THUMB_FILE_VERSION,
		mtime   = mtime,
		width   = _THUMB_SIZE,
		height  = _THUMB_SIZE,
	}
	blob := make([]u8, size_of(_Thumb_File_Header) + len(pixels), context.temp_allocator)
	mem.copy(raw_data(blob), &header, size_of(_Thumb_File_Header))
	copy(blob[size_of(_Thumb_File_Header):], pixels)
	_ = os.write_entire_file(path, blob)
}

// A valid disk entry with a matching stamp uploads straight to a texture.
@(private = "file")
_thumb_disk_load :: proc(guid: engine.Asset_GUID, mtime: i64) -> (^gfx.Texture, bool) {
	blob, rerr := os.read_entire_file(_thumb_disk_path(guid), context.temp_allocator)
	if rerr != nil do return nil, false
	if len(blob) <= size_of(_Thumb_File_Header) do return nil, false
	header := (^_Thumb_File_Header)(raw_data(blob))^
	if header.magic != _THUMB_FILE_MAGIC || header.version != _THUMB_FILE_VERSION || header.mtime != mtime {
		return nil, false
	}
	pixels := blob[size_of(_Thumb_File_Header):]
	if len(pixels) != int(header.width) * int(header.height) * 4 do return nil, false
	tex := gfx.texture_create(pixels, header.width, header.height)
	return tex, tex != nil
}

// Entries whose guid left the asset db (deleted assets) and unparseable files
// are removed — changed assets overwrite their entry in place, so this is the
// only staleness the guid-keyed layout can accumulate.
@(private = "file")
_thumb_disk_prune :: proc() {
	dir, derr := os.open(_THUMB_CACHE_DIR)
	if derr != nil do return
	subdirs, srerr := os.read_dir(dir, -1, context.temp_allocator)
	os.close(dir)
	if srerr != nil do return
	for sub in subdirs {
		if sub.type != .Directory do continue
		sub_path := fmt.tprintf("%s/%s", _THUMB_CACHE_DIR, sub.name)
		sd, sderr := os.open(sub_path)
		if sderr != nil do continue
		files, frerr := os.read_dir(sd, -1, context.temp_allocator)
		os.close(sd)
		if frerr != nil do continue
		for f in files {
			path := fmt.tprintf("%s/%s", sub_path, f.name)
			raw_guid, perr := uuid.read(strings.trim_suffix(f.name, ".thumb"))
			if perr != nil {
				os.remove(path)
				continue
			}
			if _, ok := engine.asset_db_get_path(raw_guid); !ok {
				os.remove(path)
			}
		}
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
	if _, sr := engine.transform_get_comp(tH, sprites.SpriteRenderer); sr != nil && !engine.asset_guid_is_empty(sr.sprite.guid) {
		if tex, tok := engine.texture_load(sr.sprite.guid); tok {
			if c, _, cok := sprites.sprite_quad(sr, tw, tex); cok {
				for p in c {
					grow(bmin, bmax, any_point, p)
				}
			}
		}
	}
	grow(bmin, bmax, any_point, tw.position)

	for child in t.children {
		_thumb_bounds_walk(engine.Transform_Handle(child.handle), bmin, bmax, any_point)
	}
}
