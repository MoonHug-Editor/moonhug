package drag

// Drag and drop between the editor's windows: what a drag carries, where it
// can land, and what a drop does there (docs/core/DragAndDrop.md).
//
// - A drag carries items: assets, a file or a sub-asset as a PPtr (local id
//   0 for the file), or scene objects. A window that lists them is a source:
//   it calls `source` inside imgui's drag source.
// - A drop lands on a place: the Scene view at a pixel, under an object of
//   the Hierarchy, a Project folder. What it does there is a rule: a proc
//   with @(drop={what, on}). The first rule that takes the items performs
//   the drop. While the drag hovers, the same rule says what the drop would
//   do, and the drag's tooltip shows it.
// - An inspector reference field takes the item its type admits, with no
//   rule (`items`).
//
// Window tabs drag on imgui payloads of their own: they move windows, they
// carry no content.

import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:encoding/uuid"
import im "moonhug:external/odin-imgui"
import assets "moonhug:libs/assets"
import core "moonhug:libs/core"

// One thing a drag carries.
Item :: union {
	core.PPtr, // an asset: a file (local id 0) or a sub-asset
	core.Transform_Handle, // a scene object
}

// The imgui payload type of every drag that carries items.
PAYLOAD :: "MH_DRAG"

// The Scene view at pixel (px, py) of `view`, from its top-left. `fallback`
// is where an object goes when the pointer meets nothing: the view's grid.
Scene_Place :: struct {
	view:     core.Render_View,
	px, py:   f32,
	fallback: [3]f32,
}

// Under `parent` in the Hierarchy, at child `index`, -1 for the end.
// `parent` {} is the window's background, beside the loaded scenes.
Hierarchy_Place :: struct {
	parent: core.Transform_Handle,
	index:  int,
}

// A folder of the Project window, its path.
Project_Place :: struct {
	folder: string,
}

// Where a drag can land.
Place :: union {
	Scene_Place,
	Hierarchy_Place,
	Project_Place,
}

// One offer of the drag's items to a rule.
Drop :: struct {
	items:   []Item,
	place:   Place,
	// False while the drag hovers: the rule only says whether it takes the
	// items and what it would do. True on release: it does it.
	perform: bool,
	// What the drop does, set by the rule while hovering, for the drag's
	// tooltip: "Make prefab Tank.scene". Temp-allocated.
	hint:    string,
}

// A rule: true when it takes the items, and on `perform` it has done the drop.
Drop_Proc :: proc(d: ^Drop) -> bool

// What a drop does: a proc named `drop_<name>` with @(drop={what, on}).
//
//   @(drop={what = "object", on = "project"})
//   drop_objects_in_project :: proc(d: ^drag.Drop) -> bool {
//       folder := d.place.(drag.Project_Place).folder
//       if !d.perform {
//           d.hint = "Make prefab"
//           return true
//       }
//       ...
//   }
//
// - `what` is what every item of the drag is: "object", "asset", or
//   "asset:<kind>", the kind of a file (its extension without the dot) or
//   of a sub-asset ("sprite", "mesh"), as the Project search's `t:` knows it.
// - `on` is the place: "scene" (the Scene view, Scene_Place), "hierarchy"
//   (Hierarchy_Place) or "project" (a Project folder, Project_Place).
// - Rules of one place are asked in order, a kind before plain "asset", and
//   the first that returns true takes the drop. One that does not take what
//   it is offered returns false and the next is asked.
// - Called every frame while the drag hovers: with perform false it changes
//   nothing.
// - The generated registration (prebuild/drop_gen) adds each one.
@(extension_point={attribute="drop", target="proc", fields="what on"})
drop_rule_add :: proc(what, on: string, fn: Drop_Proc) {
	context.allocator = runtime.default_allocator()
	p, ok := _place_of_name(on)
	assert(ok, "drag: @(drop) `on` is scene, hierarchy or project")
	r := _Rule{what = strings.clone(what), on = p, fn = fn}
	// A kind before plain "asset": the specific rule is asked first.
	at := len(_rules)
	if strings.has_prefix(what, "asset:") {
		for x, i in _rules do if x.on == p && x.what == "asset" {
			at = i
			break
		}
	}
	inject_at(&_rules, at, r)
}

@(private = "file")
_Rule :: struct {
	what: string,
	on:   _Place_Kind,
	fn:   Drop_Proc,
}

@(private = "file")
_Place_Kind :: enum {
	Scene,
	Hierarchy,
	Project,
}

@(private = "file")
_rules: [dynamic]_Rule

// The items of the drag in progress, default allocator.
@(private = "file")
_items: [dynamic]Item

// What the hovered target's rule says, and the frame it said it.
@(private = "file")
_hint: [256]u8
@(private = "file")
_hint_len: int
@(private = "file")
_hint_frame: i32

@(private = "file")
_place_of_name :: proc(on: string) -> (_Place_Kind, bool) {
	switch on {
	case "scene":     return .Scene, true
	case "hierarchy": return .Hierarchy, true
	case "project":   return .Project, true
	}
	return {}, false
}

@(private = "file")
_place_kind :: proc(p: Place) -> _Place_Kind {
	switch _ in p {
	case Scene_Place:     return .Scene
	case Hierarchy_Place: return .Hierarchy
	case Project_Place:   return .Project
	}
	return .Scene
}

// Inside imgui's drag source (BeginDragDropSource), every frame: this drag
// carries `items`, and its tooltip says `label`, then what the hovered
// target would do with them.
source :: proc(items: []Item, label: string) {
	context.allocator = runtime.default_allocator()
	clear(&_items)
	append(&_items, ..items)
	frame := im.GetFrameCount()
	im.SetDragDropPayload(PAYLOAD, &frame, size_of(frame))
	im.TextUnformatted(strings.clone_to_cstring(label, context.temp_allocator))
	// The target speaks the frame it is hovered: this frame or, drawn
	// after the source, the one before.
	if _hint_len > 0 && frame - _hint_frame <= 1 {
		im.TextDisabled("%s", strings.clone_to_cstring(string(_hint[:_hint_len]), context.temp_allocator))
	}
}

// The items of the drag in progress, nil when there is none.
items :: proc() -> []Item {
	p := im.GetDragDropPayload()
	if p == nil || !im.Payload_IsDataType(p, PAYLOAD) do return nil
	return _items[:]
}

// Inside a drop target (BeginDragDropTarget): offers the drag's items to the
// rules of `place`. While one takes them the target highlights (`flags` as
// imgui's) and the tooltip says what a drop does. `taken` is true while a
// rule takes them, `dropped` on the frame the drop happened.
target :: proc(place: Place, flags: im.DragDropFlags = {}) -> (taken: bool, dropped: bool) {
	its := items()
	if len(its) == 0 do return
	hint: string
	hint, taken = run(its, place, false)
	if !taken do return
	p := im.AcceptDragDropPayload(PAYLOAD, flags + {.AcceptBeforeDelivery})
	if p == nil do return false, false
	_say(hint)
	if !p.Delivery do return
	run(its, place, true)
	return true, true
}

// Asks the rules of `place` for `items` in order. `perform` false: whether
// one takes them, and what it says it would do. True: the first that takes
// them does the drop.
run :: proc(items: []Item, place: Place, perform: bool) -> (hint: string, taken: bool) {
	kind := _place_kind(place)
	for r in _rules {
		if r.on != kind || !matches(r.what, items) do continue
		d := Drop{items = items, place = place, perform = perform}
		if r.fn(&d) do return d.hint, true
	}
	return "", false
}

// Whether every item is what `what` names: "object", "asset" or
// "asset:<kind>".
matches :: proc(what: string, items: []Item) -> bool {
	if len(items) == 0 do return false
	for it in items {
		switch v in it {
		case core.Transform_Handle:
			if what != "object" do return false
		case core.PPtr:
			if what == "asset" do continue
			if !strings.has_prefix(what, "asset:") || asset_kind(v) != what[len("asset:"):] do return false
		}
	}
	return true
}

// What an asset is: the extension of its file without the dot, in lower
// case, or its sub-asset's kind. "" when the database does not know it.
asset_kind :: proc(ref: core.PPtr) -> string {
	if ref.local_id != 0 {
		for s in assets.asset_db_sub_assets(ref.guid) do if s.id == ref.local_id do return s.kind
		return ""
	}
	path, ok := assets.asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return ""
	ext := filepath.ext(path)
	if len(ext) < 2 do return ""
	return strings.to_lower(ext[1:], context.temp_allocator)
}

// What an asset is called: its sub-asset's name, or its file's name without
// the extension.
asset_name :: proc(ref: core.PPtr) -> string {
	if ref.local_id != 0 {
		for s in assets.asset_db_sub_assets(ref.guid) do if s.id == ref.local_id && s.name != "" do return s.name
	}
	path, ok := assets.asset_db_get_path(uuid.Identifier(ref.guid))
	if !ok do return "asset"
	return filepath.stem(path)
}

// The assets of `items`, nil unless every item is one. Temp-allocated.
assets_of :: proc(items: []Item) -> []core.PPtr {
	out := make([dynamic]core.PPtr, 0, len(items), context.temp_allocator)
	for it in items {
		ref, is_asset := it.(core.PPtr)
		if !is_asset do return nil
		append(&out, ref)
	}
	return out[:]
}

// The objects of `items`, nil unless every item is one. Temp-allocated.
objects_of :: proc(items: []Item) -> []core.Transform_Handle {
	out := make([dynamic]core.Transform_Handle, 0, len(items), context.temp_allocator)
	for it in items {
		h, is_object := it.(core.Transform_Handle)
		if !is_object do return nil
		append(&out, h)
	}
	return out[:]
}

@(private = "file")
_say :: proc(hint: string) {
	n := copy(_hint[:], hint)
	_hint_len = n
	_hint_frame = im.GetFrameCount()
}
