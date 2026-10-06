package thumbnails

// Asset thumbnails for the project view's grid mode and the inspector's
// Preview pane. GPU-resident cache keyed by guid, invalidated by the asset
// db's file stamp, backed by a disk cache under library/thumbnails so
// thumbnails survive sessions. The cache names no asset type: renderers
// register per extension (register, register_sub), and the engine's live in
// plugins/engine/editor/previews.
//
// Generation is budgeted: the project view REQUESTS a thumbnail for each
// visible cell (get), misses queue, and tick handles a few per frame. A valid
// disk entry uploads straight to a texture, everything else renders. The tick
// runs at the top of the frame, BEFORE any view draws, so a renderer that
// spawns content for its picture tears it down before the frame's visible
// rendering.
//
// Rendered thumbnails persist asynchronously: the readback submits one frame
// after the render (the frame command buffer must be submitted first) and the
// fence is polled, never waited on, so generation costs no GPU sync stalls.
// Disk entries are guid-keyed (library/thumbnails/<xx>/<guid>.thumb, raw RGBA
// + header), so a changed asset overwrites its entry in place. The only stale
// files are deleted assets', pruned once at startup.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import assets "moonhug:host/assets"
import core "moonhug:host/core"
import gfx "moonhug:host/gfx"
import "moonhug:editor/subassets"

// Draws one thumbnail into `target` (SIZE x SIZE): the asset itself for
// sub 0, otherwise its sub-asset with that persistent id. The pass is the
// renderer's to begin and end. False keeps the type icon.
Renderer :: proc(path: string, guid: core.Asset_GUID, sub: core.Local_ID, target: ^gfx.Render_Target) -> bool

// The thumbnail edge in pixels.
SIZE :: 128

_THUMB_JOBS_PER_FRAME :: 2
_THUMB_CACHE_DIR :: "library/thumbnails"
_THUMB_FILE_MAGIC :: u32(0x4254484D) // "MHTB"
// Bump when the render style changes — every disk entry invalidates.
_THUMB_FILE_VERSION :: u32(2) // v2: mesh-part thumbs lit

_Thumb :: struct {
	tex:   ^gfx.Texture, // nil = generation produced nothing, keep the icon
	mtime: i64,
}

// One cache entry per asset OR per sub-asset: sub 0 is the asset itself,
// otherwise the sub-asset's persistent id (a mesh part).
_Thumb_Key :: struct {
	guid: core.Asset_GUID,
	sub:  core.Local_ID,
}

// Rendered this frame — the readback can only submit after frame_end, so it
// waits one tick.
_Thumb_Save :: struct {
	key:   _Thumb_Key,
	mtime: i64,
	tex:   ^gfx.Texture,
}

_Thumb_Download :: struct {
	key:   _Thumb_Key,
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

@(private = "file") _thumbs: map[_Thumb_Key]_Thumb
@(private = "file") _thumb_queue: [dynamic]_Thumb_Key
@(private = "file") _thumb_queued: map[_Thumb_Key]bool
@(private = "file") _thumb_saves: [dynamic]_Thumb_Save
@(private = "file") _thumb_downloads: [dynamic]_Thumb_Download
@(private = "file") _thumb_pruned: bool
@(private = "file") _thumb_rt: ^gfx.Render_Target

// Renderers by extension: one for the asset itself, one for its
// sub-assets. Registered once at startup, they live for the whole run.
@(private = "file") _renderers: map[string]Renderer
@(private = "file") _sub_renderers: map[string]Renderer

// The renderer for assets with extension `ext` (".png"). The asset gets a
// thumbnail in the project view's grid.
register :: proc(ext: string, render: Renderer) {
	context.allocator = runtime.default_allocator()
	_renderers[strings.clone(ext)] = render
}

// The renderer for sub-assets of assets with extension `ext` (a model's mesh
// parts). Sub-assets that carry their own image never reach it.
register_sub :: proc(ext: string, render: Renderer) {
	context.allocator = runtime.default_allocator()
	_sub_renderers[strings.clone(ext)] = render
}

@(private = "file")
_thumb_supported :: proc(path: string) -> bool {
	return filepath.ext(path) in _renderers
}

// The cached thumbnail texture for an asset, as an imgui texture id. A miss
// (or stale stamp) queues generation and returns false — the caller draws the
// type icon this frame. While regenerating, the previous texture keeps showing.
get :: proc(path: string) -> (id: rawptr, ok: bool) {
	if !_thumb_supported(path) do return nil, false
	return _thumb_lookup(path, 0)
}

// The preview for a SUB-ASSET, as a texture region. A sub-asset that carries
// its own image (a sprite slice — the crop of the resident texture) returns
// immediately. Anything else (a mesh part) goes through the same render +
// disk-cache pipeline as asset thumbnails, keyed (guid, sub id).
get_sub :: proc(path: string, sub: subassets.Sub_Asset) -> (id: rawptr, uv0, uv1: [2]f32, ok: bool) {
	if sub.image != nil {
		return sub.image, sub.uv0, sub.uv1, true
	}
	tid, tok := _thumb_lookup(path, sub.id)
	return tid, {0, 0}, {1, 1}, tok
}

@(private = "file")
_thumb_lookup :: proc(path: string, sub: core.Local_ID) -> (id: rawptr, ok: bool) {
	raw_guid, gok := assets.asset_db_get_guid(path)
	if !gok do return nil, false
	key := _Thumb_Key{core.Asset_GUID(raw_guid), sub}
	stamp, sok := assets.asset_db_get_stamp(path)
	if !sok do return nil, false
	mtime := stamp.mtime._nsec

	th, has := _thumbs[key]
	if !has || th.mtime != mtime {
		if !(key in _thumb_queued) {
			_thumb_queued[key] = true
			append(&_thumb_queue, key)
		}
	}
	if has && th.tex != nil {
		return gfx.texture_imgui_id(th.tex), true
	}
	return nil, false
}

// Budgeted generation, called once per frame before any view draws (the frame
// command buffer must be live, no pass active).
tick :: proc() {
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
			_thumb_disk_write(d.key, d.mtime, pixels)
		}
		unordered_remove(&_thumb_downloads, i)
	}
	for save in _thumb_saves {
		th, has := _thumbs[save.key]
		if !has || th.tex != save.tex do continue // superseded before the save
		if dl := gfx.texture_download_begin(save.tex); dl != nil {
			append(&_thumb_downloads, _Thumb_Download{key = save.key, mtime = save.mtime, dl = dl})
		}
	}
	clear(&_thumb_saves)

	for _ in 0 ..< _THUMB_JOBS_PER_FRAME {
		if len(_thumb_queue) == 0 do break
		key := _thumb_queue[0]
		ordered_remove(&_thumb_queue, 0)
		delete_key(&_thumb_queued, key)

		path, pok := assets.asset_db_get_path(uuid.Identifier(key.guid))
		if !pok do continue // deleted since the request
		stamp, sok := assets.asset_db_get_stamp(path)
		if !sok do continue
		mtime := stamp.mtime._nsec

		tex, from_disk := _thumb_disk_load(key, mtime)
		if !from_disk {
			if _thumb_rt == nil do _thumb_rt = gfx.rt_create(SIZE, SIZE)
			tex = _thumb_render(key, path)
			if tex != nil {
				append(&_thumb_saves, _Thumb_Save{key = key, mtime = mtime, tex = tex})
			}
		}
		if prev, has := _thumbs[key]; has && prev.tex != nil {
			gfx.texture_destroy(prev.tex)
		}
		_thumbs[key] = _Thumb{tex = tex, mtime = mtime}
	}
}

shutdown :: proc() {
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
}

@(private = "file")
_thumb_render :: proc(key: _Thumb_Key, path: string) -> ^gfx.Texture {
	table := _renderers if key.sub == 0 else _sub_renderers
	render, has := table[filepath.ext(path)]
	if !has do return nil
	if !render(path, key.guid, key.sub, _thumb_rt) do return nil
	return gfx.rt_snapshot(_thumb_rt)
}

// Fan-out by the guid's first two hex chars.
// Sub-asset entries suffix the sub id: <guid>_s<id>.thumb.
@(private = "file")
_thumb_disk_path :: proc(key: _Thumb_Key) -> string {
	id := uuid.to_string(uuid.Identifier(key.guid), context.temp_allocator)
	if key.sub != 0 {
		return fmt.tprintf("%s/%s/%s_s%d.thumb", _THUMB_CACHE_DIR, id[:2], id, i64(key.sub))
	}
	return fmt.tprintf("%s/%s/%s.thumb", _THUMB_CACHE_DIR, id[:2], id)
}

@(private = "file")
_thumb_disk_write :: proc(key: _Thumb_Key, mtime: i64, pixels: []u8) {
	os.make_directory("library")
	os.make_directory(_THUMB_CACHE_DIR)
	id := uuid.to_string(uuid.Identifier(key.guid), context.temp_allocator)
	os.make_directory(fmt.tprintf("%s/%s", _THUMB_CACHE_DIR, id[:2]))
	path := _thumb_disk_path(key)

	header := _Thumb_File_Header{
		magic   = _THUMB_FILE_MAGIC,
		version = _THUMB_FILE_VERSION,
		mtime   = mtime,
		width   = SIZE,
		height  = SIZE,
	}
	blob := make([]u8, size_of(_Thumb_File_Header) + len(pixels), context.temp_allocator)
	mem.copy(raw_data(blob), &header, size_of(_Thumb_File_Header))
	copy(blob[size_of(_Thumb_File_Header):], pixels)
	_ = os.write_entire_file(path, blob)
}

// A valid disk entry with a matching stamp uploads straight to a texture.
@(private = "file")
_thumb_disk_load :: proc(key: _Thumb_Key, mtime: i64) -> (^gfx.Texture, bool) {
	blob, rerr := os.read_entire_file(_thumb_disk_path(key), context.temp_allocator)
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
			name := strings.trim_suffix(f.name, ".thumb")
			// Sub-asset entries carry a _s<id> suffix — the owning guid
			// decides staleness for them too.
			if us := strings.index(name, "_s"); us >= 0 {
				name = name[:us]
			}
			raw_guid, perr := uuid.read(name)
			if perr != nil {
				os.remove(path)
				continue
			}
			if _, ok := assets.asset_db_get_path(raw_guid); !ok {
				os.remove(path)
			}
		}
	}
}
