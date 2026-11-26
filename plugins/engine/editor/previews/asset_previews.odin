package previews

// Inspector Preview pane drawers for the engine's visual assets — textures
// (the real texture, sharp at any size), models, scenes (their thumbnail,
// scaled) and materials (a sphere, orbited). A selected SUB-asset previews itself: a sprite slice
// shows its crop, a mesh part its rendered thumb — resolved through the same
// subassets registry + thumbnail cache the project window uses. Audio's
// waveform preview registers from its own package the same way.

import "core:encoding/uuid"
import "core:fmt"
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

// The pane's choices, kept for the person on this machine: the shape a
// material previews on, the light of the 3D previews, and whether models,
// scenes and clips stand on a floor (off until asked for).
Asset_Preview_Settings :: struct {
	material_shape: Preview_Shape,
	light:          Preview_Light,
	floor:          bool,
}

// How a 3D preview is lit.
Preview_Light :: enum u8 {
	// A warm key light from above and a soft fill from the other side, fixed
	// to the world, with the open scene's sky (or a neutral one) for
	// reflections and ambient light. The key light casts the floor's shadow.
	Studio,
	// One light from the camera: every side the camera turns to is lit.
	Headlight,
}

@(user_settings={name="Asset Preview"})
asset_preview_settings: Asset_Preview_Settings

// The line under a preview's picture that says what the asset holds: a
// texture's size, format and memory, a mesh's vertices and triangles, a
// clip's length. Called right after the picture's item. It sits outside the
// picture, in the room _pv_area leaves, so it covers nothing.
@(private = "file")
_pv_info :: proc(text: string) {
	im.SetCursorPosX(im.GetCursorPosX() + 6)
	im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
	im.TextUnformatted(strings.clone_to_cstring(text, context.temp_allocator))
	im.PopStyleColor()
}

// The pane's area for the picture: what is left under the title bar, less
// the info line under the picture.
@(private = "file")
_pv_area :: proc() -> im.Vec2 {
	avail := im.GetContentRegionAvail()
	avail.y -= im.GetTextLineHeight() + im.GetStyle().ItemSpacing.y
	return avail
}

// The width a row of toggle buttons with these labels takes, 2 apart.
@(private = "file")
_pv_buttons_width :: proc(labels: ..cstring) -> f32 {
	w := f32(0)
	for l, i in labels {
		w += im.CalcTextSize(l).x + im.GetStyle().FramePadding.x * 2
		if i > 0 do w += 2
	}
	return w
}

// "4.0 MiB" and the like.
@(private = "file")
_pv_bytes :: proc(n: i64) -> string {
	if n < 1024 do return fmt.tprintf("%d B", n)
	if n < 1024 * 1024 do return fmt.tprintf("%.1f KiB", f64(n) / 1024)
	return fmt.tprintf("%.1f MiB", f64(n) / (1024 * 1024))
}

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
	inspector.mapAssetPreview[".mat"] = _preview_material
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
	if _pv_shadow_rt != nil {
		gfx.rt_destroy(_pv_shadow_rt)
		_pv_shadow_rt = nil
	}
	_pv_drawn = {}
	material_sphere_shutdown()
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

// The channels a texture's preview shows.
@(private = "file")
Pv_Channel :: enum u8 {
	R,
	G,
	B,
	A,
}

@(private = "file") _PV_CHANNEL_LABELS := [Pv_Channel]cstring{.R = "R", .G = "G", .B = "B", .A = "A"}

// What the texture preview shows, back to all channels and the full size
// when another texture is selected.
@(private = "file") _tex_pv: struct {
	guid:     engine.Asset_GUID,
	channels: bit_set[Pv_Channel],
	mip:      i32,
}

// A texture's format as a short name, and its bytes per pixel.
@(private = "file")
_pv_format :: proc(tex: ^gfx.Texture) -> (name: string, bytes: i64) {
	#partial switch tex.format {
	case .R8G8B8A8_UNORM:      return "RGBA8", 4
	case .R8G8B8A8_UNORM_SRGB: return "RGBA8 sRGB", 4
	case .R16G16B16A16_FLOAT:  return "RGBA16F", 8
	case .R32G32B32A32_FLOAT:  return "RGBA32F", 16
	}
	return fmt.tprintf("%v", tex.format), 4
}

// Textures draw the RESIDENT texture, not the 128px thumb, sharp at pane
// size, through the texture view shader: the channels the toggles keep, one
// mip level, alpha over a checkerboard. A selected slice draws its crop.
_preview_texture :: proc(path: string) {
	raw_guid, gok := engine.asset_db_get_guid(path)
	if !gok do return
	guid := engine.Asset_GUID(raw_guid)
	tex, tok := engine.texture_load(guid)
	if !tok || tex.gfx == nil do return
	if guid != _tex_pv.guid do _tex_pv = {guid = guid, channels = {.R, .G, .B, .A}}

	uv0, uv1 := [2]f32{0, 0}, [2]f32{1, 1}
	w, h := f32(tex.width), f32(tex.height)
	slice := false
	if s, sok := _preview_selected_sub(path); sok {
		if rect, rok := engine.texture_sprite_rect(tex, s.id); rok {
			uv0 = {rect.rect.x / w, rect.rect.y / h}
			uv1 = {(rect.rect.x + rect.rect.z) / w, (rect.rect.y + rect.rect.w) / h}
			w, h = rect.rect.z, rect.rect.w
			slice = true
		}
	}

	// On the title bar: the channel toggles, then the mip level when there is
	// more than one.
	mips := tex.gfx.mips
	MIP_WIDTH :: f32(96)
	bar := _pv_buttons_width("R", "G", "B", "A")
	if mips > 1 do bar += im.GetStyle().ItemSpacing.x + MIP_WIDTH
	inspector.preview_bar_controls(bar)
	for c in Pv_Channel {
		if c != .R do im.SameLine(0, 2)
		on := c in _tex_pv.channels
		widgets.toggle_button(_PV_CHANNEL_LABELS[c], &on)
		if on != (c in _tex_pv.channels) do _tex_pv.channels ~= {c}
	}
	widgets.tooltip("The channels shown. One color channel alone, or alpha alone, shows as grey.")
	_tex_pv.mip = clamp(_tex_pv.mip, 0, max(mips - 1, 0))
	if mips > 1 {
		im.SameLine()
		im.SetNextItemWidth(MIP_WIDTH)
		im.SliderInt("##mip", &_tex_pv.mip, 0, mips - 1, "Mip %d")
		widgets.tooltip("The mip level shown: each is half the size of the one above.")
	}

	area := _pv_area()
	if area.x < 16 || area.y < 16 do return
	scale := min(area.x / max(w, 1), area.y / max(h, 1))
	dw, dh := max(w * scale, 1), max(h * scale, 1)
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(dw), i32(dh))
	opts := u64(transmute(u8)_tex_pv.channels) | u64(_tex_pv.mip) << 8
	if _pv_needs_draw({kind = .Texture, guid = guid, sub = i64(uv0.x * 65536) ~ i64(uv0.y * 4096), size = {i32(dw), i32(dh)}, opts = opts}) {
		params := gfx.Texture_View_Params{
			uv       = {uv0.x, uv0.y, uv1.x, uv1.y},
			channels = {
				1 if .R in _tex_pv.channels else 0,
				1 if .G in _tex_pv.channels else 0,
				1 if .B in _tex_pv.channels else 0,
				1 if .A in _tex_pv.channels else 0,
			},
			view     = {f32(_tex_pv.mip), 8, 1 if .A in _tex_pv.channels else 0, 0},
		}
		gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0, 0, 0, 1})
		gfx.draw_fullscreen(gfx.TEXTURE_VIEW_SHADER, {tex.gfx}, (^[size_of(gfx.Texture_View_Params)]u8)(&params)[:])
		gfx.pass_end()
	}
	pos := im.GetCursorScreenPos()
	p0 := im.Vec2{pos.x + (area.x - dw) * 0.5, pos.y + (area.y - dh) * 0.5}
	// The backdrop the 3D previews clear to.
	im.DrawList_AddRectFilled(im.GetWindowDrawList(), pos, pos + area, im.GetColorU32ImVec4({0.16, 0.16, 0.18, 1}))
	im.DrawList_AddImage(im.GetWindowDrawList(),
		im.TextureRef{_TexID = im.TextureID(uintptr(gfx.rt_imgui_id(_mesh_pv_rt)))},
		p0, im.Vec2{p0.x + dw, p0.y + dh})
	im.Dummy(area)

	format, bpp := _pv_format(tex.gfx)
	gw, gh := i64(tex.gfx.width), i64(tex.gfx.height)
	bytes: i64
	for level in 0 ..< max(mips, 1) do bytes += max(gw >> uint(level), 1) * max(gh >> uint(level), 1) * bpp
	if slice {
		_pv_info(fmt.tprintf("%d x %d slice of %d x %d", i32(w), i32(h), tex.width, tex.height))
	} else if gw != i64(tex.width) || gh != i64(tex.height) {
		_pv_info(fmt.tprintf("%d x %d (source %d x %d)  %s  %d mips  %s", gw, gh, tex.width, tex.height, format, mips, _pv_bytes(bytes)))
	} else {
		_pv_info(fmt.tprintf("%d x %d  %s  %d mips  %s", gw, gh, format, mips, _pv_bytes(bytes)))
	}
}

// The preview of a scene file's sub-asset. A texture source (a noise map) draws its
// resident texture, sharp at pane size and made again after every edit. A
// material gets the preview a material file has. Any other type draws its
// thumbnail, as its file would.
_preview_scene_sub_asset :: proc(path: string, scene: engine.Asset_GUID, s: subassets.Sub_Asset) {
	key := engine.asset_key(engine.PPtr{guid = scene, local_id = s.id})
	if engine.asset_type(key) == "noise" {
		if tex, ok := engine.texture_load(key); ok {
			_preview_draw_region(gfx.texture_imgui_id(tex.gfx), {0, 0}, {1, 1}, f32(tex.width), f32(tex.height))
		}
		return
	}
	if engine.asset_type(key) == "mat" {
		_preview_material_key(key)
		return
	}
	if tid, uv0, uv1, ok := thumbnails.get_sub(path, s); ok do _preview_draw_region(tid, uv0, uv1, 1, 1)
}

// --- When a live preview redraws -----------------------------------------------
// The live previews (model, scene, clip) render into _mesh_pv_rt only when
// their picture would change: another asset, part or clip, a new pane size,
// orbit or zoom input, a clip's time, or a change to asset content. An idle
// preview shows the picture it rendered last, so a selected scene costs
// nothing per frame however large it is. Asset content changes arrive through
// asset_on_changed_previews (a changed, removed or reimported asset) and the
// material cache's version (live material edits).

@(private = "file")
_Pv_Kind :: enum u8 {
	None,
	Texture,
	Model,
	Scene,
	Clip,
	Material,
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
	light_turn:       f32,
	content:          u64,    // _pv_content
	materials:        u64,    // engine.material_cache_version
	sky:              u64,    // engine.environment_version
	prefs:            Asset_Preview_Settings,
	opts:             u64,    // the kind's own choices: a texture's channels and mip, a material's shape
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
	k.light_turn = _pv_light_turn
	k.content = _pv_content
	k.materials = engine.material_cache_version
	k.sky = engine.environment_version
	k.prefs = asset_preview_settings
	if k == _pv_drawn do return false
	_pv_drawn = k
	return true
}

// Asset content changes: the live previews redraw (_pv_needs_draw). A file
// changed or went away, or an artifact changed (a model, a texture, a
// shader). The previewed scene's own asset respawns its instance.
@(asset_on_changed)
asset_on_changed_previews :: proc(guid: engine.Asset_GUID, path: string, change: engine.Asset_Change) {
	_pv_content += 1
	if guid == _scene_pv_guid do _scene_pv_stale = true
}

// --- Live mesh preview --------------------------------------------------------
// The mesh preview: the model (or the selected part) rendered into an RT at
// pane size when its picture changes, orbited by dragging, zoomed by wheel. No scene spawn —
// one Draw_Mesh command straight through render_execute (white unlit, the
// filter carries no materials).

_mesh_pv_rt: ^gfx.Render_Target
_PV_YAW :: f32(0.8)
_PV_PITCH :: f32(0.5)
_mesh_pv_yaw: f32 = _PV_YAW
_mesh_pv_pitch: f32 = _PV_PITCH
_mesh_pv_zoom: f32 = 1
// The studio light's turn around Y, radians: a Shift+drag on the picture.
_pv_light_turn: f32

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

	inspector.preview_bar_controls(_pv_stage_width())
	_pv_stage_toggles()
	avail := _pv_area()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))

	if _pv_needs_draw({kind = .Model, guid = guid, sub = i64(part), size = {i32(avail.x), i32(avail.y)}}) {
		center := (mesh.aabb_min + mesh.aabb_max) * 0.5
		radius := max(linalg.length(mesh.aabb_max - mesh.aabb_min) * 0.5, 0.01)
		rv, forward := _pv_view(center, radius, avail)
		// The mesh draws directly, with no material: white, lit.
		draw_mesh :: proc(data: rawptr) {
			mesh := (^engine.Mesh)(data)
			for sub in mesh.submeshes {
				gfx.draw_mesh(mesh.gpu, nil, linalg.MATRIX4F32_IDENTITY, {1, 1, 1, 1}, gfx.LIT_SHADER, sub.first_index, sub.index_count, nil, nil)
			}
		}
		_pv_render(rv, forward, center, radius, mesh.aabb_min.y, {color = draw_mesh, depth = draw_mesh, data = mesh})
	}

	_pv_image_orbit(_mesh_pv_rt, avail)

	triangles := 0
	for sm in mesh.submeshes do triangles += int(sm.index_count / 3)
	size := mesh.aabb_max - mesh.aabb_min
	info := fmt.tprintf("%d vertices  %d triangles  %d %s  %.2f x %.2f x %.2f", mesh.gpu.vertex_count, triangles, len(mesh.submeshes), "material" if len(mesh.submeshes) == 1 else "materials", size.x, size.y, size.z)
	if engine.mesh_is_skinned(mesh) do info = fmt.tprintf("%s  %d joints", info, len(mesh.joint_names))
	_pv_info(info)
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

// The width _pv_stage_toggles takes.
@(private = "file")
_pv_stage_width :: proc(floor := true) -> f32 {
	if floor do return _pv_buttons_width(icons.ICON_MD_GRID_ON, icons.ICON_MD_LIGHT_MODE)
	return _pv_buttons_width(icons.ICON_MD_LIGHT_MODE)
}

// The light toggle and the floor toggle of the 3D previews, on the current
// line.
@(private = "file")
_pv_stage_toggles :: proc(floor := true) {
	if floor {
		on := asset_preview_settings.floor
		widgets.toggle_button(icons.ICON_MD_GRID_ON, &on)
		asset_preview_settings.floor = on
		widgets.tooltip("A floor under the asset, with its shadow in studio light.")
		im.SameLine(0, 2)
	}
	studio := asset_preview_settings.light == .Studio
	widgets.toggle_button(icons.ICON_MD_LIGHT_MODE, &studio)
	asset_preview_settings.light = .Studio if studio else .Headlight
	widgets.tooltip("Studio light: a key light and a fill, with a sky for reflections. Shift+drag the picture to turn the light. Off: one light from the camera.")
}

// The studio key light's direction, the way it travels, and the fill's. From
// the starting view the key comes from the upper left, so the shadow falls to
// the right of the asset, and the fill from the right.
_PV_KEY :: [3]f32{0.56, -0.61, -0.18}
_PV_FILL :: [3]f32{-0.68, -0.54, 0.06}

// What a 3D preview draws, for _pv_render: the asset in color, and the asset
// alone into the open shadow pass.
@(private = "file")
_Pv_Draw :: struct {
	color: proc(data: rawptr),
	depth: proc(data: rawptr),
	data:  rawptr,
}

@(private = "file") _pv_shadow_rt: ^gfx.Render_Target

_PV_SHADOW_SIZE :: 1024

// The floor's surface: matte, so it shows the shadow and no mirror image of
// the sky. Kept here: a draw reads its material bytes when the pass ends.
@(private = "file") _pv_floor_surface := gfx.Lit_Material{params = {0, 0.15, 0, 1}, uv = {1, 1, 0, 0}}

// Renders a 3D preview into _mesh_pv_rt: the asset at `center` within
// `radius`, standing on `floor_y`, through the view `rv`. In studio light the
// key light casts a shadow onto the floor from a shadow map of the asset.
@(private = "file")
_pv_render :: proc(rv: engine.Render_View, forward, center: [3]f32, radius, floor_y: f32, draw: _Pv_Draw, floor := true) {
	studio := asset_preview_settings.light == .Studio
	floor := floor && asset_preview_settings.floor
	// The studio lights and the sky, turned around Y by a Shift+drag.
	turned :: proc(d: [3]f32) -> [3]f32 {
		c, sn := math.cos(_pv_light_turn), math.sin(_pv_light_turn)
		return {c * d.x + sn * d.z, d.y, -sn * d.x + c * d.z}
	}
	key := turned(linalg.normalize(_PV_KEY))

	cascades: gfx.Shadow_Cascades
	if studio && floor && draw.depth != nil {
		if _pv_shadow_rt == nil do _pv_shadow_rt = gfx.rt_create(_PV_SHADOW_SIZE, _PV_SHADOW_SIZE, .Depth)
		r := radius * 1.1
		up := [3]f32{0, 1, 0} if abs(key.y) < 0.99 else [3]f32{1, 0, 0}
		back := r * 2 + 1
		eye := center - key * back
		depth_range := back + r * 4
		vp := gfx.matrix4_ortho_z01(-r, r, -r, r, 0, depth_range) * linalg.matrix4_look_at_f32(eye, center, up)
		gfx.pass_begin_target(_pv_shadow_rt, nil)
		gfx.set_view_proj(vp, eye)
		draw.depth(draw.data)
		gfx.pass_end()
		cascades = gfx.Shadow_Cascades{
			tex         = gfx.rt_depth_texture(_pv_shadow_rt),
			count       = 1,
			light_index = 0,
			vp          = {0 = vp},
			rects       = {0 = {0, 0, 1, 1}},
			world_texel = {0 = 2 * r / _PV_SHADOW_SIZE},
			depth_bias  = {0 = 0.05 / depth_range},
			normal_bias = 1.5,
			distance    = 1e6,
		}
	}

	if studio {
		gfx.set_lights([]gfx.Light{
			{kind = .Directional, direction = key, color = {1, 0.96, 0.9}, intensity = 0.9, culling_mask = ~u32(0)},
			{kind = .Directional, direction = turned(linalg.normalize(_PV_FILL)), color = {0.8, 0.86, 1}, intensity = 0.25, culling_mask = ~u32(0)},
		}, 0.2)
	} else {
		gfx.set_lights([]gfx.Light{{kind = .Directional, direction = forward, color = {1, 1, 1}, intensity = 1, culling_mask = ~u32(0)}}, 0.35)
	}
	if studio do engine.environment_preview_prepare()
	gfx.pass_begin_target(_mesh_pv_rt, [4]f32{0.16, 0.16, 0.18, 1})
	gfx.set_view_proj(rv.view_proj, rv.cam_pos)
	if studio do engine.environment_preview_bind(_pv_light_turn)
	if cascades.count > 0 do gfx.set_shadow_cascades(cascades)
	if floor {
		// A plate a little wider than the asset: it stays inside the view's
		// depth range, so it never ends in a horizon line.
		size := radius * 2.2
		model := linalg.matrix4_translate_f32({center.x, floor_y, center.z}) * linalg.matrix4_scale_f32({size, 1, size})
		gfx.draw_mesh(_material_shape(.Plane), nil, model, {0.5, 0.5, 0.52, 1}, gfx.LIT_SHADER, 0, 0, (^[size_of(gfx.Lit_Material)]u8)(&_pv_floor_surface)[:], nil)
	}
	draw.color(draw.data)
	gfx.pass_end()
	gfx.set_lights_default() // the preview's lights must not leak into later passes
}

// The RT drawn over an InvisibleButton (the button captures the drag even
// when the cursor leaves the pane mid-gesture), orbit + zoom input. With
// Shift the drag turns the studio light and its sky. A double click goes
// back to the starting angle, framing and light.
_pv_image_orbit :: proc(rt: ^gfx.Render_Target, avail: im.Vec2) {
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##orbit_preview", avail)
	im.DrawList_AddImage(im.GetWindowDrawList(),
		im.TextureRef{_TexID = im.TextureID(uintptr(gfx.rt_imgui_id(rt)))},
		pos, im.Vec2{pos.x + avail.x, pos.y + avail.y})
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		_mesh_pv_yaw, _mesh_pv_pitch, _mesh_pv_zoom = _PV_YAW, _PV_PITCH, 1
		_pv_light_turn = 0
	}
	if im.IsItemActive() && im.IsMouseDragging(.Left, 0) {
		delta := im.GetIO().MouseDelta
		if im.GetIO().KeyShift {
			// The light and its sky turn with the pointer, the view stays.
			_pv_light_turn += delta.x * 0.01
		} else {
			_mesh_pv_yaw += delta.x * 0.01
			_mesh_pv_pitch = clamp(_mesh_pv_pitch + delta.y * 0.01, -1.45, 1.45)
		}
	}
	if im.IsItemHovered() {
		if wheel := im.GetIO().MouseWheel; wheel != 0 {
			_mesh_pv_zoom = clamp(_mesh_pv_zoom * math.pow(f32(1.12), -wheel), 0.3, 4)
		}
	}
}

// A preview of objects in the preview world: what the view sees, drawn
// through the engine's render commands, cast into the shadow map the same way.
@(private = "file")
_pv_render_commands :: proc(rv: engine.Render_View, forward, center: [3]f32, radius, floor_y: f32) {
	Commands :: struct {
		rv:   engine.Render_View,
		list: []engine.Render_Command,
	}
	cmds := make([dynamic]engine.Render_Command, 0, 64, context.temp_allocator)
	engine.render_collect_commands(rv, &cmds)
	c := Commands{rv, cmds[:]}
	color :: proc(data: rawptr) {
		c := (^Commands)(data)
		engine.render_execute(c.rv, c.list)
	}
	depth :: proc(data: rawptr) {
		engine.render_execute_depth((^Commands)(data).list)
	}
	_pv_render(rv, forward, center, radius, floor_y, {color = color, depth = depth, data = &c})
}

// Prefab (.scene) preview: the prefab instantiated and orbited live, rendered
// when its picture changes (_pv_needs_draw). Content goes on the reserved
// preview layer and the view masks to it, so the open scene's content never
// bleeds in.
// The scene instance behind the preview, kept alive between frames. Spawning
// is a full deserialize of the scene file and every object it creates, so
// doing it per frame pegged a core on a 35-object scene. It holds the preview
// world's one kept instance (preview_world_hold): the world is rendered
// whole, so a clip preview's rig or a previous scene left in it would be
// drawn into this picture.
@(private = "file") _scene_pv_guid: engine.Asset_GUID
@(private = "file") _scene_pv_root: engine.Transform_Handle
@(private = "file") _scene_pv_center: [3]f32
@(private = "file") _scene_pv_radius: f32
@(private = "file") _scene_pv_objects: int
@(private = "file") _scene_pv_floor: f32
// The previewed scene's file changed since it was spawned (asset_on_changed_previews).
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

	// A selected sub-asset previews itself: an asset the scene file holds.
	if s, sok := _preview_selected_sub(path); sok {
		_preview_scene_sub_asset(path, guid, s)
		return
	}

	inspector.preview_bar_controls(_pv_stage_width())
	_pv_stage_toggles()
	avail := _pv_area()
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
			preview_world_hold(_scene_pv_release)
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
			_scene_pv_objects = _pv_count_objects(spawned)
			_scene_pv_floor = bmin.y
		}

		rv, forward := _pv_view(_scene_pv_center, _scene_pv_radius, avail)
		_pv_render_commands(rv, forward, _scene_pv_center, _scene_pv_radius, _scene_pv_floor)
	}

	_pv_image_orbit(_mesh_pv_rt, avail)
	if _scene_pv_root != {} {
		d := _scene_pv_radius * 2
		_pv_info(fmt.tprintf("%d %s  about %.1f across", _scene_pv_objects, "object" if _scene_pv_objects == 1 else "objects", d))
	}
}

// The objects in the tree under `root`, `root` included.
@(private = "file")
_pv_count_objects :: proc(root: engine.Transform_Handle) -> int {
	w := engine.ctx_world()
	t := engine.pool_get(&w.transforms, engine.Handle(root))
	if t == nil do return 0
	n := 1
	for c in t.children do n += _pv_count_objects(engine.Transform_Handle(c.handle))
	return n
}

// A clip inside a model: the model's skeleton posed by the clip, scrubbed by a
// slider or playing, orbitable like the other 3D previews. The rig lives in
// the preview world between frames as its one kept instance (see
// _preview_scene) and is rebuilt when the selection moves to another clip.
@(private = "file") _clip_pv: struct {
	owner:   engine.Asset_GUID,
	id:      engine.Local_ID,
	rig:     Model_Clip_Rig,
	time:    f32,
	playing: bool,
	center:  [3]f32,
	radius:  f32,
	floor:   f32,
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
		preview_world_hold(_clip_pv_release)
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
		_clip_pv.floor = bmin.y
	}
	rig := &_clip_pv.rig

	// The light and floor toggles, then the transport: play toggle and a
	// scrub over the clip's length.
	inspector.preview_bar_controls(_pv_stage_width())
	_pv_stage_toggles()
	if im.Button(_clip_pv.playing ? icons.ICON_MD_PAUSE : icons.ICON_MD_PLAY_ARROW) do _clip_pv.playing = !_clip_pv.playing
	widgets.tooltip(_clip_pv.playing ? "Pause" : "Play")
	im.SameLine()
	im.SetNextItemWidth(im.GetContentRegionAvail().x)
	if im.SliderFloat("##clip_time", &_clip_pv.time, 0, rig.length, "%.2f s") do _clip_pv.playing = false
	if _clip_pv.playing {
		// The full frame rate while it plays: the editor's idle rate would
		// show the clip in steps.
		gfx.keep_awake(0.25)
		_clip_pv.time += im.GetIO().DeltaTime
		if _clip_pv.time > rig.length do _clip_pv.time -= rig.length
	}

	avail = _pv_area()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))
	// Posed and rendered when the picture changes: every frame while it
	// plays, once per scrub while it is paused.
	if _pv_needs_draw({kind = .Clip, guid = owner, sub = i64(clip_id), size = {i32(avail.x), i32(avail.y)}, time = _clip_pv.time}) {
		model_clip_rig_pose(rig, _clip_pv.time)
		rv, forward := _pv_view(_clip_pv.center, _clip_pv.radius, avail)
		_pv_render_commands(rv, forward, _clip_pv.center, _clip_pv.radius, _clip_pv.floor)
	}
	_pv_image_orbit(_mesh_pv_rt, avail)
	_pv_info(fmt.tprintf("%.2f s", rig.length))
}

@(private = "file") _PV_SHAPE_LABELS := [Preview_Shape]cstring{.Collar = "Ball", .Ball = "Plain", .Sphere = "Sphere", .Cube = "Cube", .Plane = "Plane"}

// The inspector's preview of a material file: the sphere at the pane's size,
// orbited by a drag and zoomed by the wheel, drawn again when the material
// or the view changes (_pv_needs_draw).
_preview_material :: proc(path: string) {
	raw_guid, known := engine.asset_db_get_guid(path)
	if !known do return
	_preview_material_key(engine.Asset_GUID(raw_guid))
}

// The same for any material by its key: a file's, or a material a scene
// file holds as a sub-asset.
_preview_material_key :: proc(guid: engine.Asset_GUID) {

	// The shape it shows on, one button each, kept in the preview settings.
	shape := &asset_preview_settings.material_shape
	// The plain ball has no button.
	if shape^ < min(Preview_Shape) || shape^ >= .Ball do shape^ = .Collar
	inspector.preview_bar_controls(_pv_buttons_width("Ball", "Sphere", "Cube", "Plane") + im.GetStyle().ItemSpacing.x + _pv_stage_width(floor = false))
	for s in Preview_Shape {
		if s == .Ball do continue
		if s != min(Preview_Shape) do im.SameLine(0, 2)
		on := shape^ == s
		widgets.toggle_button(_PV_SHAPE_LABELS[s], &on)
		if on && shape^ != s do shape^ = s
	}
	im.SameLine()
	_pv_stage_toggles(floor = false)

	avail := _pv_area()
	if avail.x < 32 || avail.y < 32 do return
	if _mesh_pv_rt == nil do _mesh_pv_rt = gfx.rt_create(1, 1)
	gfx.rt_resize(_mesh_pv_rt, i32(avail.x), i32(avail.y))

	if _pv_needs_draw({kind = .Material, guid = guid, size = {i32(avail.x), i32(avail.y)}, opts = u64(shape^)}) {
		// The shader ball is looked at a little under its middle, so its
		// ball, the part the eye goes to, sits in the picture's middle.
		look := [3]f32{0, -0.15, 0} if shape^ == .Collar || shape^ == .Ball else [3]f32{}
		rv, forward := _pv_view(look, 1, avail)
		Shape :: struct {
			guid:  engine.Asset_GUID,
			shape: Preview_Shape,
		}
		d := Shape{guid, shape^}
		draw :: proc(data: rawptr) {
			d := (^Shape)(data)
			_material_shape_draw(d.guid, d.shape)
		}
		_pv_render(rv, forward, {}, 1, -1, {color = draw, data = &d}, floor = false)
	}
	_pv_image_orbit(_mesh_pv_rt, avail)

	if mat, ok := engine.material_load(guid); ok {
		shader := fmt.tprintf("%v", mat.shader)
		if !engine.asset_guid_is_empty(mat.custom_shader.guid) {
			if p, pok := engine.asset_db_get_path(uuid.Identifier(mat.custom_shader.guid)); pok do shader = filepath.base(p)
		}
		_pv_info(fmt.tprintf("%s  %v", shader, mat.surface))
	}
}
