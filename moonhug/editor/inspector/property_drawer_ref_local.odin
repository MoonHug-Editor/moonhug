package inspector

import "core:fmt"
import "core:mem"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "../../engine"
import "../undo"
import "moonhug:editor/widgets"

// Material icon codepoints, duplicated from editor/material_icons.odin — the
// inspector package cannot import editor (editor imports inspector).
ICON_MD_CLOSE  :: "\ue5cd"
ICON_MD_SEARCH :: "\uef7a"

// Shared picker-popup search state. One popup is open at a time, so a single
// buffer serves all pickers; it resets when a popup (re)opens.
@(private)
_picker_search_buf: [128]byte

// Draw the popup's search input (focused on open) and return the lowercase
// query (temp-allocated).
_picker_search_bar :: proc() -> []string {
	if im.IsWindowAppearing() {
		mem.zero(&_picker_search_buf, len(_picker_search_buf))
		im.SetKeyboardFocusHere()
	}
	im.SetNextItemWidth(220)
	im.InputTextWithHint("##picker_search", "Search", cstring(raw_data(_picker_search_buf[:])), uint(len(_picker_search_buf)))
	return widgets.search_terms(string(cstring(raw_data(_picker_search_buf[:]))))
}

// Unity-like reference field row: Label [value][x][pick]. Single click on the
// value pings the target, double click opens/selects it (out params); [x]
// clears (shown before [pick] only when set); [pick] opens the picker popup.
// Returns true when the popup should open. When dropped_asset is non-nil, the
// value button accepts ASSET_PATH drag-drops and writes the dropped path
// (temp-allocated) there. When dropped_pptr is non-nil it also accepts
// ASSET_PPTR — a sub-asset dragged from the project window (a sprite slice,
// later a mesh part) — and sets dropped_pptr_ok.
//
// An EMPTY field ("None") has nothing to ping or open, so its value area acts
// as the pick button — clicking anywhere on the row opens the picker instead of
// hitting a dead zone.
_picker_field_row :: proc(label: cstring, display: string, has_value: bool, value_clicked: ^bool, cleared: ^bool, value_double_clicked: ^bool = nil, dropped_asset: ^string = nil, dropped_pptr: ^engine.PPtr = nil, dropped_pptr_ok: ^bool = nil) -> bool {
	display, has_value := display, has_value
	// Every reference drawer routes its value text through here, so the mixed
	// substitution lives here too rather than in each drawer. Showing the active
	// object's asset name would read as if the whole selection pointed at it.
	//
	// `has_value` goes false with it: the ping / open / clear affordances act on
	// one specific reference, and a mixed row names none. The row then behaves
	// like an empty one — clicking it opens the picker, which assigns to the
	// whole selection and resolves the mixed state.
	if current_field_mixed {
		display = MIXED_VALUE_TEXT
		has_value = false
	}

	field_row(label)

	BTN_W :: f32(24)
	// field_row left the cursor at the value column, so this is that column's
	// width. The buttons size themselves, hence reading it rather than relying on
	// the item width field_row also set.
	avail := im.GetContentRegionAvail().x
	value_w := avail - BTN_W - current_field_trailing_w
	if has_value do value_w -= BTN_W

	value_label := strings.clone_to_cstring(
		fmt.tprintf("%s##val_%s", display, label), context.temp_allocator,
	)
	// This button shows a reference VALUE, so make it read as a FIELD, not a
	// button: left-aligned text (like a text field) and the frame-bg fill (so
	// it matches the other input boxes rather than the distinct button gray).
	im.PushStyleVarImVec2(.ButtonTextAlign, im.Vec2{0, 0.5})
	im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.FrameBg)^)
	im.PushStyleColorImVec4(.ButtonHovered, im.GetStyleColorVec4(.FrameBgHovered)^)
	im.PushStyleColorImVec4(.ButtonActive, im.GetStyleColorVec4(.FrameBgActive)^)
	value_pressed := im.Button(value_label, {value_w, 0})
	im.PopStyleColor(3)
	im.PopStyleVar()
	open_picker := false
	if value_pressed {
		if has_value {
			value_clicked^ = true
		} else {
			open_picker = true
		}
	}
	if has_value && value_double_clicked != nil && im.IsItemHovered({}) && im.IsMouseDoubleClicked(.Left) {
		value_double_clicked^ = true
	}
	if (dropped_asset != nil || dropped_pptr != nil) && im.BeginDragDropTarget() {
		if dropped_asset != nil {
			if payload := im.AcceptDragDropPayload("ASSET_PATH"); payload != nil && payload.Data != nil {
				path := string((cast([^]u8)payload.Data)[:payload.DataSize])
				dropped_asset^ = strings.clone(path, context.temp_allocator)
			}
		}
		if dropped_pptr != nil {
			if payload := im.AcceptDragDropPayload("ASSET_PPTR"); payload != nil && payload.Data != nil && payload.DataSize == size_of(engine.PPtr) {
				dropped_pptr^ = (cast(^engine.PPtr)payload.Data)^
				if dropped_pptr_ok != nil do dropped_pptr_ok^ = true
			}
		}
		im.EndDragDropTarget()
	}

	if has_value {
		im.SameLine(0, 0)
		clear_label := strings.clone_to_cstring(
			fmt.tprintf("%s##clear_%s", ICON_MD_CLOSE, label), context.temp_allocator,
		)
		if im.Button(clear_label, {BTN_W, 0}) {
			cleared^ = true
		}
	}

	im.SameLine(0, 0)
	pick_label := strings.clone_to_cstring(
		fmt.tprintf("%s##pick_%s", ICON_MD_SEARCH, label), context.temp_allocator,
	)
	return im.Button(pick_label, {BTN_W, 0}) || open_picker
}

@(property_drawer={type = engine.Ref_Local, priority = 0})
draw_ref_local_property :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	ref_ptr := cast(^engine.Ref_Local)ptr
	spec := current_field_ref_target
	keys := ref_target_keys(spec)

	owner_root_scene := ref_local_owner_root_scene()
	display := _ref_local_display(ref_ptr^, spec)
	has_value := ref_ptr.local_id != 0 || ref_ptr.handle != {}

	popup_id := strings.clone_to_cstring(
		fmt.tprintf("ref_local_picker##%s", label), context.temp_allocator,
	)

	value_clicked, value_double, cleared: bool
	if _picker_field_row(label, display, has_value, &value_clicked, &cleared, &value_double) {
		im.OpenPopup(popup_id)
	}
	// Single click: ping (reveal + flash, selection untouched). Double click:
	// select in the hierarchy.
	if value_double {
		if tH, ok := _ref_local_target_transform(ref_ptr^); ok {
			engine.inspector_request_select(tH)
		}
	} else if value_clicked {
		if tH, ok := _ref_local_target_transform(ref_ptr^); ok {
			engine.inspector_request_ping(tH)
		}
	}
	if cleared {
		ref_ptr^ = {}
		mark_inspector_changed()
	}

	if im.BeginPopup(popup_id) {
		if len(keys) == 0 {
			im.TextDisabled("Add `ref:\"TypeName\"` or `ref:\"@Tag\"` field tag to enable picker")
		} else {
			search := _picker_search_bar()
			// Single Scene tab: a Ref_Local is a same-file local_id — fields
			// that can also reference assets use engine.Ref (PPtr).
			if im.BeginTabBar("##picker_tabs") {
				if im.BeginTabItem("Scene") {
					if im.Selectable("None") {
						ref_ptr^ = {}
						mark_inspector_changed()
					}
					im.Separator()
					objects := _find_objects_of_types(keys, owner_root_scene)
					shown := 0
					for obj in objects {
						if !widgets.search_match(obj.name, search) {
							continue
						}
						shown += 1
						row := strings.clone_to_cstring(
							fmt.tprintf("%s##%d_%d", obj.name, obj.handle.index, obj.handle.generation),
							context.temp_allocator,
						)
						if im.Selectable(row) {
							ref_ptr.handle = obj.handle
							ref_ptr.local_id = engine.sm_local_id_get_or_mint(owner_root_scene, obj.handle)
							mark_inspector_changed()
						}
					}
					if shown == 0 {
						im.TextDisabled("(no matches in loaded scenes)")
					}
					im.EndTabItem()
				}
				im.EndTabBar()
			}
		}
		im.EndPopup()
	}
}

// The transform a ref points at (the component's owner for component refs).
@(private)
_ref_local_target_transform :: proc(r: engine.Ref_Local) -> (engine.Transform_Handle, bool) {
	w := engine.ctx_world()
	if !engine.world_pool_valid(w, r.handle) do return {}, false
	if r.handle.type_key == .Transform {
		return engine.Transform_Handle(r.handle), true
	}
	raw := engine.world_pool_get(w, r.handle)
	if raw == nil do return {}, false
	return (cast(^engine.CompData)raw).owner, true
}

// The scene a picked target's local_id is minted against: the owner's root
// scene, from the inspector owner stack. A window drawing this picker OUTSIDE
// the inspector must push its owner (undo.push_component_owner) or nothing is
// minted and the reference survives only until the next scene reload.
ref_local_owner_root_scene :: proc() -> ^engine.Scene {
	o, ok := undo.current_owner()
	if !ok || o.kind != .Pooled do return nil
	w := engine.ctx_world()
	owner_tH: engine.Transform_Handle
	if o.handle.type_key == .Transform {
		owner_tH = engine.Transform_Handle(o.handle)
	} else {
		raw := engine.world_pool_get(w, o.handle)
		if raw == nil do return nil
		base := cast(^engine.CompData)raw
		owner_tH = base.owner
	}
	return engine.sm_get_root_scene_of_transform(owner_tH)
}

@(private)
// `spec` is the field's raw `ref:` value, for the Missing text.
_ref_local_display :: proc(r: engine.Ref_Local, spec: string) -> string {
	if r.local_id == 0 && r.handle == {} {
		return "None"
	}
	w := engine.ctx_world()
	if engine.world_pool_valid(w, r.handle) {
		// For component types: handle points at the component, owner is on CompData.
		// For .Transform: handle points at the Transform itself.
		if r.handle.type_key == .Transform {
			t := engine.pool_get(&w.transforms, r.handle)
			if t != nil && t.name != "" do return t.name
		} else {
			raw := engine.world_pool_get(w, r.handle)
			if raw != nil {
				base := cast(^engine.CompData)raw
				t := engine.pool_get(&w.transforms, engine.Handle(base.owner))
				if t != nil && t.name != "" {
					return fmt.tprintf("%s (%v)", t.name, r.handle.type_key)
				}
			}
		}
	}
	// Once-set reference whose target is gone (deleted object, dead handle):
	// "Missing (what the field asked for)".
	return ref_target_missing_text(spec)
}

// Objects matching ANY key in `keys`, concatenated, then narrowed by the
// field's `has:` filter. An object carrying two matching components appears
// once per component, which is right — they are different pick targets.
_find_objects_of_types :: proc(keys: []engine.TypeKey, root_scene: ^engine.Scene) -> []engine.Found_Object {
	found: []engine.Found_Object
	if len(keys) == 1 {
		found = engine.sm_find_objects_of_type(keys[0], root_scene)
	} else {
		out := make([dynamic]engine.Found_Object, context.temp_allocator)
		for k in keys {
			append(&out, ..engine.sm_find_objects_of_type(k, root_scene))
		}
		found = out[:]
	}
	return _filter_objects_has(found)
}

// Keeps the candidates whose OWNER object carries at least one component in
// the field's `has:` list. No filter, or a filter naming nothing, keeps all —
// a typo in `has:` then shows every object rather than none, which is the
// visible failure.
@(private = "file")
_filter_objects_has :: proc(found: []engine.Found_Object) -> []engine.Found_Object {
	if current_field_has_filter == "" do return found
	need := ref_target_keys(current_field_has_filter)
	if len(need) == 0 do return found
	w := engine.ctx_world()
	out := make([dynamic]engine.Found_Object, 0, len(found), context.temp_allocator)
	for obj in found {
		// The candidate is a transform for a `ref:"Transform"` field, a
		// component otherwise — either way, the object is the owner.
		tH := obj.handle
		if tH.type_key != .Transform {
			raw := engine.world_pool_get(w, tH)
			if raw == nil do continue
			tH = engine.Handle((cast(^engine.CompData)raw).owner)
		}
		t := engine.pool_get(&w.transforms, tH)
		if t == nil do continue
		keep := false
		for c in t.components {
			for k in need do if c.handle.type_key == k { keep = true; break }
			if keep do break
		}
		if keep do append(&out, obj)
	}
	return out[:]
}

// A reference field with NO pick or clear buttons — the value is fixed by what
// it describes, not chosen by the user (e.g. the Prefab Asset a Prefab Instance
// came from). Click semantics match a normal Ref field: single click pings,
// double click opens.
//
// Not `im.BeginDisabled` styling: the value is still interactive, just not
// re-assignable, so it keeps the field look and hover feedback.
// `inline_label`: draw "Label:" immediately before the value instead of at the
// inspector's shared label column. A compact header row wants the two hugging
// each other, not the wide label gutter a property row uses.
picker_field_row_readonly :: proc(
	label: cstring,
	display: string,
	clicked: ^bool,
	double_clicked: ^bool = nil,
	inline_label := false,
) {
	if inline_label {
		if len(string(label)) > 0 {
			im.AlignTextToFramePadding()
			im.TextUnformatted(label)
			im.SameLine()
		}
	} else {
		field_row(label)
	}

	value_label := strings.clone_to_cstring(
		fmt.tprintf("%s##ro_%s", display, label), context.temp_allocator,
	)
	im.PushStyleVarImVec2(.ButtonTextAlign, im.Vec2{0, 0.5})
	im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.FrameBg)^)
	im.PushStyleColorImVec4(.ButtonHovered, im.GetStyleColorVec4(.FrameBgHovered)^)
	im.PushStyleColorImVec4(.ButtonActive, im.GetStyleColorVec4(.FrameBgActive)^)
	// Fill the remaining width, but never wider than the text needs plus a
	// little padding — a short path should not stretch a whole column.
	avail := im.GetContentRegionAvail().x
	want := im.CalcTextSize(value_label, nil, true).x + im.GetStyle().FramePadding.x * 4
	pressed := im.Button(value_label, {min(avail, want), 0})
	im.PopStyleColor(3)
	im.PopStyleVar()

	if pressed do clicked^ = true
	if double_clicked != nil && im.IsItemHovered({}) && im.IsMouseDoubleClicked(.Left) {
		double_clicked^ = true
	}
}
