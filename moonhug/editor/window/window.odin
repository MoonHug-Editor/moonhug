package window

// Plugin-openable editor windows (docs/core/Views.md). A window is DECLARED with
// @(editor_window={id, title, icon, width, height, closed}) on its
// content-draw proc, which prebuild registers here, and OPENED by id, usually
// from a @(menu_item) proc.
//
// A window opens as instances. open(id) shows its plain instance, open(id,
// asset) the instance for that asset, so two assets are edited side by side,
// and open_another(id) one more plain instance, as Add Tab does. Each
// instance has its own imgui id (`<id>`, `<id>/<asset guid>`, or `<id>/<n>`)
// and so its own dock place and size in imgui.ini, and its own state: the
// draw proc receives the instance and keeps what it needs in `data`, which the
// `closed` proc frees when the instance closes. A new asset instance with
// nothing saved docks beside an open instance of the same window, or opens
// offset from it when that one floats, so it never hides behind it. An asset
// instance's tab shows the asset's name.
//
// The registry and the open instances live here for the process lifetime,
// and the editor persists the open keys (open_keys, open_saved). width and
// height apply only while imgui.ini has no entry for the instance
// (Cond.FirstUseEver). Window CONTENTS live in the owning plugin.
//
// An editor subpackage like menu/inspector/undo: plugin editor/ packages import
// it, the editor root draws it once per frame (draw_all).

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:libs/assets"
import core "moonhug:libs/core"
import "moonhug:libs/log"
import "moonhug:editor/session"

// One open instance of a registered window.
Window :: struct {
	id:     string,          // the registered window's id, shared by its instances
	key:    string,          // the instance's imgui id: `id`, `id/<asset guid>` for an asset's instance, `id/<n>` for another plain one. Owned
	asset:  core.Asset_GUID, // the asset it is open for, {} for the plain instance
	// The window's own state for this instance: its draw proc sets it, its
	// closed proc frees it.
	data:   rawptr,
	open:   bool,
	reg:    int,   // index into _registry
	dock:   im.ID, // its dock node last frame, 0 while floating: a new sibling docks there
	pos:    im.Vec2, // its position last frame: a new sibling opens offset from it
	placed: bool,  // drawn once, so its place is imgui's to keep
	used:   u64,   // when it was last clicked in or opened: the highest is last(id)
	drawn:  u64,   // the draw pass it was last drawn in, so draw_all skips what draw(id) drew
	// The key of the view that hosts it (a workspace view), "" for a window
	// of its own. A hosted instance never draws as a window: its host draws
	// its content (draw_content) where it places it. Owned.
	host:   string,
}

Draw_Proc  :: proc(w: ^Window)
Close_Proc :: proc(w: ^Window)

_Registered :: struct {
	id:           string,  // stable handle from the attribute
	plain_title:  string,  // the title as declared, without icon or id
	icon:         string,  // the glyph before the label
	draw:         Draw_Proc,
	closed:       Close_Proc, // frees an instance's `data`, nil when the window keeps none
	default_size: im.Vec2, // {} = imgui's default
	canvas:       bool,    // edge to edge: no window padding, no scrollbars, the wheel stays with the content
	// The @(editor_window) that declared it, with its file and line, as
	// rendered by the generator. Shown on the tab's menu button with debug tooltips on.
	origin:       string,
}

_registry: [dynamic]_Registered
_windows: [dynamic]^Window // the open instances, pointer-stable for their state
_focus_request: ^Window    // the instance to focus next frame
_pass: u64                 // draw passes so far: draw_all ends one
_use_count: u64            // clicks and opens so far, for Window.used

// Asked before a closed instance goes: true keeps it open. The editor
// installs one that asks before a view holding unapplied edits closes
// (view_close_prompt.odin). nil closes every instance.
close_guard: proc(w: ^Window) -> bool

// Asked when open or open_another makes an instance while a hosted
// instance's content draws, and when open shows an instance that is hosted.
// `opener` is the hosted instance drawing then (nil for none), `w` the
// instance, `created` whether open made it. A hook that hosts `w` keeps it
// out of the dock. The workspace view installs one: a window opened from a
// frame's view opens chained to that frame, and one already in a frame is
// shown there.
host_hook: proc(opener, w: ^Window, created: bool)

// The hosted instance whose content draws now (draw_content), nil outside one.
@(private = "file")
_drawing: ^Window

// The instance whose content the mouse was over, and the imgui frame it was.
@(private = "file")
_hovered: ^Window
@(private = "file")
_hovered_frame: i32

// Declares a dockable editor window whose content the proc draws.
//
// `id` identifies it, and its instances, in imgui.ini. `title` and `icon` (a
// Material Symbols name without ICON_MD_) label its plain instance's tab,
// `width` and `height` size an instance's first appearance. `closed` frees
// an instance's state. Open it with window.open, usually from a @(menu_item).
//
// Called by the generated _register_editor_windows (editor_window_gen). The
// imgui window name is "<icon> <label>###<key>": the icon and label show, the
// key stays the imgui id whatever they are.
@(extension_point={attribute="editor_window", target="proc", fields="id title icon width height closed canvas"})
register :: proc(id: string, title: string, icon: string, draw: Draw_Proc, width, height: f32, origin := "", closed: Close_Proc = nil, canvas := false) {
	// Process-global: never borrows the caller's allocator.
	context.allocator = runtime.default_allocator()
	for &r in _registry {
		if r.id == id {
			log.errorf("editor_window: duplicate id %q (%s ignored)", id, title)
			return
		}
	}
	append(&_registry, _Registered{
		id           = id,
		plain_title  = title,
		icon         = icon,
		draw         = draw,
		closed       = closed,
		default_size = {width, height},
		origin       = origin,
		canvas       = canvas,
	})
}

// Every registered window's plain title and id, for imgui.ini migration
// (the ini names a window "###<id>" now that titles carry icons).
Title_Id :: struct {
	title: string,
	id:    string,
}

registered :: proc(allocator := context.temp_allocator) -> []Title_Id {
	out := make([]Title_Id, len(_registry), allocator)
	for r, i in _registry do out[i] = {r.plain_title, r.id}
	return out
}

// The keys of every open instance. The editor persists them in
// editor_settings so a session reopens what was open (imgui.ini already keeps
// position and size, but not whether the instance existed).
open_keys :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(_windows), allocator)
	for w in _windows do if w.open && w.host == "" do append(&out, w.key)
	return out[:]
}

// Reopens the instances named by a previous open_keys. Unknown windows (a
// package that is no longer installed) and assets that are gone are skipped
// quietly, unlike `open`.
open_saved :: proc(keys: []string) {
	for key in keys {
		id, asset, ok := _parse_key(key)
		if !ok do continue
		ri := _registered_index(id)
		if ri < 0 do continue
		if asset != {} {
			if _, known := assets.asset_db_get_path(uuid.Identifier(asset)); !known do continue
		}
		if find(key) == nil do _create(ri, asset, key)
	}
}

// Shows the instance of the window declared under `id` for `asset`, or its
// plain instance without one, and focuses it. Returns it, nil for an unknown
// id.
open :: proc(id: string, asset := core.Asset_GUID{}) -> ^Window {
	ri := _registered_index(id)
	if ri < 0 {
		log.errorf("editor_window: unknown id %q (declare it with @(editor_window={{id=...}}))", id)
		return nil
	}
	w := _find(ri, asset)
	created := w == nil
	if created do w = _create(ri, asset)
	_use_count += 1
	w.used = _use_count
	if host_hook != nil && (w.host != "" || (created && _drawing != nil)) {
		host_hook(_drawing, w, created)
		if w.host != "" do return w
	}
	_focus_request = w
	return w
}

// The open instance under the mouse this frame or the last, nil for none: its
// content, not its tab. Maximize View acts on it.
hovered :: proc() -> ^Window {
	if _hovered == nil || _hovered_frame < im.GetFrameCount() - 1 do return nil
	for w in _windows do if w == _hovered && w.open do return w
	return nil
}

// Focuses an open instance next frame, as open does.
focus :: proc(w: ^Window) {
	_focus_request = w
	_use_count += 1
	w.used = _use_count
}

// Opens one more plain instance of the window declared under `id`, as Add
// Tab does: `id/2`, `id/3` and so on, the lowest number not open. Returns it,
// nil for an unknown id.
open_another :: proc(id: string) -> ^Window {
	ri := _registered_index(id)
	if ri < 0 {
		log.errorf("editor_window: unknown id %q (declare it with @(editor_window={{id=...}}))", id)
		return nil
	}
	n := 2
	for find(fmt.tprintf("%s/%d", id, n)) != nil do n += 1
	w := _create(ri, {}, fmt.tprintf("%s/%d", id, n))
	if host_hook != nil && _drawing != nil {
		host_hook(_drawing, w, true)
		if w.host != "" do return w
	}
	_focus_request = w
	return w
}

// Whether a window is declared under `id`: the plugin that declares it may
// be absent.
is_registered :: proc(id: string) -> bool {
	return _registered_index(id) >= 0
}

// The open instances of the window declared under `id`, plain first.
instances :: proc(id: string, allocator := context.temp_allocator) -> []^Window {
	out := make([dynamic]^Window, allocator)
	for w in _windows do if w.open && w.id == id && w.key == id do append(&out, w)
	for w in _windows do if w.open && w.id == id && w.key != id do append(&out, w)
	return out[:]
}

// Closes the instance whose key is `key`.
close :: proc(key: string) {
	for w in _windows do if w.key == key do w.open = false
}

// The open instance whose key is `key`, nil when there is none. For work that
// runs outside the draw, such as a dialog's action.
find :: proc(key: string) -> ^Window {
	for w in _windows do if w.open && w.key == key do return w
	return nil
}

// The origin of the window an instance key belongs to, for debug tooltips.
// Unknown keys (a built-in view, which is not a registered window) answer "".
origin_of :: proc(key: string) -> string {
	id, _, _ := _parse_key(key)
	for &r in _registry {
		if r.id == id do return r.origin
	}
	return ""
}

// Whether any instance of the window declared under `id` is open.
is_open :: proc(id: string) -> bool {
	for w in _windows do if w.open && w.id == id do return true
	return false
}

// Draws the open instances of the window declared under `id` now, for a
// window that has to draw at a set point of the frame (the Scene view, inside
// the preview pose). draw_all then skips them.
draw :: proc(id: string) {
	for i := 0; i < len(_windows); i += 1 {
		w := _windows[i]
		if w.open && w.id == id && w.host == "" do _draw_instance(w)
	}
}

// One call per editor frame, after the views that draw at a set point.
// Removal happens here, the frame after the close button flips `open`.
// Instances draw in the order they opened, so an earlier one has its place
// when a later one looks for a sibling to dock beside.
draw_all :: proc() {
	for i := len(_windows) - 1; i >= 0; i -= 1 {
		w := _windows[i]
		if w.open do continue
		if close_guard != nil && close_guard(w) {
			w.open = true
			continue
		}
		_destroy(i)
	}
	for i := 0; i < len(_windows); i += 1 {
		w := _windows[i]
		if w.open && w.host == "" && w.drawn != _pass + 1 do _draw_instance(w)
	}
	_pass += 1
}

// --- Hosting ---------------------------------------------------------------

// The instance whose key is `key`, hosted by the view `host`: an open one
// moves there, a missing one opens from the key (`id`, `id/<asset guid>`,
// `id/<n>`). nil when the key names no registered window, or an asset that
// is gone.
host_open :: proc(key: string, host: string) -> ^Window {
	context.allocator = runtime.default_allocator()
	w := find(key)
	if w == nil {
		id, asset, ok := _parse_key(key)
		if !ok do return nil
		ri := _registered_index(id)
		if ri < 0 do return nil
		if asset != {} {
			if _, known := assets.asset_db_get_path(uuid.Identifier(asset)); !known do return nil
		}
		w = _create(ri, asset, key)
	}
	if w.host != host {
		delete(w.host)
		w.host = strings.clone(host)
	}
	return w
}

// The open instances the view `host` hosts (temp).
hosted_by :: proc(host: string, allocator := context.temp_allocator) -> []^Window {
	out := make([dynamic]^Window, allocator)
	for w in _windows do if w.open && w.host == host do append(&out, w)
	return out[:]
}

// Gives a hosted instance back its own window. It docks beside an instance
// of the same window, as a new one does.
host_release :: proc(w: ^Window) {
	context.allocator = runtime.default_allocator()
	delete(w.host)
	w.host = ""
	w.placed = false
}

// Draws a hosted instance's content into the current window, which its host
// sized and placed. A canvas window's host gives it no padding and no
// scrollbars (is_canvas).
draw_content :: proc(w: ^Window) {
	w.drawn = _pass + 1
	prev := _drawing
	_drawing = w
	_registry[w.reg].draw(w)
	_drawing = prev
	// Over its host, which counted as hovered when it began: the hosted
	// instance is the one under the mouse.
	if im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
		_hovered = w
		_hovered_frame = im.GetFrameCount()
	}
	if im.IsWindowHovered(im.HoveredFlags_ChildWindows) && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)) {
		_use_count += 1
		w.used = _use_count
	}
}

// Whether the instance draws edge to edge (@(editor_window) canvas).
is_canvas :: proc(w: ^Window) -> bool {
	return _registry[w.reg].canvas
}

// The instance's tab title, "<icon> <label>###<key>" with the star while its
// asset has unsaved changes, for a host's tab bar.
title :: proc(w: ^Window) -> cstring {
	return session.view_title(_title(w))
}

// The instance's state, made from `init` on first use. It lives on the
// default allocator, since it outlives frames. A window whose state owns no
// memory needs no closed proc: the instance frees `data` when it closes.
state :: proc(w: ^Window, init: $T) -> ^T {
	if w.data == nil {
		p := new(T, runtime.default_allocator())
		p^ = init
		w.data = p
	}
	return (^T)(w.data)
}

// The open instance of the window declared under `id` that was clicked in
// or opened last, nil when none is open. Code outside a view that needs one
// of its instances (a menu action, the bridge) acts on this one.
last :: proc(id: string) -> ^Window {
	best: ^Window
	for w in _windows do if w.open && w.id == id && (best == nil || w.used > best.used) do best = w
	return best
}

@(private = "file")
_draw_instance :: proc(w: ^Window) {
	w.drawn = _pass + 1
	r := &_registry[w.reg]
	if r.default_size != {} {
		im.SetNextWindowSize(r.default_size, .FirstUseEver)
	}
	if !w.placed {
		w.placed = true
		if sibling := _sibling(w, docked = true); sibling != nil {
			im.SetNextWindowDockID(sibling.dock, .FirstUseEver)
		} else if sibling := _sibling(w, docked = false); sibling != nil {
			im.SetNextWindowPos(sibling.pos + _SIBLING_OFFSET, .FirstUseEver)
		}
	}
	if _focus_request == w {
		im.SetNextWindowFocus()
		_focus_request = nil
	}
	// NoCollapse matches every view: no collapse triangle when the window
	// floats. A star on the tab while the instance's asset has unsaved
	// changes. A canvas view's padding is popped right after Begin, so the
	// tooltips and popups raised over it keep theirs.
	flags: im.WindowFlags = {.NoCollapse}
	if r.canvas {
		flags += {.NoScrollbar, .NoScrollWithMouse}
		im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	}
	visible := im.Begin(session.view_title(_title(w)), &w.open, flags)
	if r.canvas do im.PopStyleVar()
	if visible {
		if im.IsWindowHovered(im.HoveredFlags_ChildWindows) {
			_hovered = w
			_hovered_frame = im.GetFrameCount()
		}
		r.draw(w)
		if im.IsWindowHovered(im.HoveredFlags_RootAndChildWindows) && (im.IsMouseClicked(.Left) || im.IsMouseClicked(.Right) || im.IsMouseClicked(.Middle)) {
			_use_count += 1
			w.used = _use_count
		}
	}
	w.dock = im.GetWindowDockID()
	w.pos = im.GetWindowPos()
	im.End()
}

shutdown :: proc() {
	for len(_windows) > 0 do _destroy(len(_windows) - 1)
	delete(_windows)
	_windows = nil
	delete(_registry)
	_registry = nil
}

@(private = "file")
_registered_index :: proc(id: string) -> int {
	for &r, ri in _registry do if r.id == id do return ri
	return -1
}

// The plain instance (key `id`) without an asset, the asset's instance with one.
@(private = "file")
_find :: proc(ri: int, asset: core.Asset_GUID) -> ^Window {
	for w in _windows {
		if !w.open || w.reg != ri || w.asset != asset do continue
		if asset != {} || w.key == w.id do return w
	}
	return nil
}

// A new instance. `key` defaults to `id`, or `id/<asset guid>` for an asset.
@(private = "file")
_create :: proc(ri: int, asset: core.Asset_GUID, key := "") -> ^Window {
	context.allocator = runtime.default_allocator()
	r := &_registry[ri]
	w := new(Window)
	w^ = {id = r.id, reg = ri, asset = asset, open = true}
	switch {
	case key != "":   w.key = strings.clone(key)
	case asset == {}: w.key = strings.clone(r.id)
	case:             w.key = fmt.aprintf("%s/%s", r.id, uuid.to_string(uuid.Identifier(asset), context.temp_allocator))
	}
	if asset != {} do session.view_asset_set(w.key, asset)
	_use_count += 1
	w.used = _use_count
	append(&_windows, w)
	return w
}

// The instance's state goes through its window's closed proc, then the
// instance itself.
@(private = "file")
_destroy :: proc(i: int) {
	w := _windows[i]
	if closed := _registry[w.reg].closed; closed != nil {
		closed(w)
	} else if w.data != nil {
		free(w.data, runtime.default_allocator())
		w.data = nil
	}
	// An instance reopened under the same key keeps the mapping.
	if w.asset != {} && find(w.key) == nil do session.view_asset_clear(w.key)
	if _focus_request == w do _focus_request = nil
	ordered_remove(&_windows, i)
	context.allocator = runtime.default_allocator()
	delete(w.key)
	delete(w.host)
	free(w)
}

// How far a new instance opens from a floating sibling: one title bar down
// and right, so both stay visible.
@(private = "file")
_SIBLING_OFFSET :: im.Vec2{32, 32}

// An open, already drawn instance of the same window, one in a dock node
// with `docked`, a floating one without.
@(private = "file")
_sibling :: proc(w: ^Window, docked: bool) -> ^Window {
	for other in _windows {
		if other == w || !other.open || !other.placed || other.reg != w.reg do continue
		if (other.dock != 0) == docked do return other
	}
	return nil
}

// "<icon> <label>###<key>". The plain instance's label is the window's title,
// an asset instance's the asset's file name without its extension.
@(private = "file")
_title :: proc(w: ^Window) -> cstring {
	r := &_registry[w.reg]
	label := r.plain_title
	if w.asset != {} {
		if path, ok := assets.asset_db_get_path(uuid.Identifier(w.asset)); ok do label = filepath.stem(path)
	}
	return fmt.ctprintf("%s %s###%s", r.icon, label, w.key)
}

// A key's window id and asset: `id`, `id/<asset guid>`, or `id/<n>` for
// another plain instance, which has no asset.
@(private = "file")
_parse_key :: proc(key: string) -> (id: string, asset: core.Asset_GUID, ok: bool) {
	slash := strings.index_byte(key, '/')
	if slash < 0 do return key, {}, true
	suffix := key[slash + 1:]
	if g, err := uuid.read(suffix); err == nil do return key[:slash], core.Asset_GUID(g), true
	if _, is_number := strconv.parse_int(suffix); is_number do return key[:slash], {}, true
	return "", {}, false
}
