package editor

// Gizmo settings (docs/Gizmos.md): which gizmos the scene and game views
// show, from their view menus.
//
// - Each view's "Gizmos" toggle shows or hides every gizmo and icon in it.
//   Handles and the transform gizmo stay in the scene view either way, and so
//   do gameplay shapes (.Game).
// - "Gizmo Settings" (both views, shared): the icon size, and per component
//   type with an @(on_draw_gizmos) hook whether its icon and its gizmo show.
//   The gizmo dispatcher applies them around each hook (gizmos.with_icons,
//   gizmos.with_shapes), so hook code never checks them.
// - All of it persists in the editor settings, per type by name: type keys
//   are not stable across builds.

import "base:runtime"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "../engine"
import "moonhug:editor/handles"
import "moonhug:editor/widgets"

Gizmo_Part :: enum {
	Icon,
	Gizmo,
}

// The scene view's Gizmos toggle. The game view's is game_gizmos.
@(view_menu={view="Scene", label="Gizmos"})
scene_gizmos := true

// Per component type name, the parts the settings hide. Cross-frame state:
// default allocator, keys owned.
@(private = "file")
_hidden: map[string]bit_set[Gizmo_Part]

// What the settings show of a component type's gizmo hook.
gizmo_type_shown :: proc(type_name: string) -> bit_set[Gizmo_Part] {
	return ~_hidden[type_name]
}

gizmo_type_set :: proc(type_name: string, part: Gizmo_Part, shown: bool) {
	context.allocator = runtime.default_allocator()
	hidden := _hidden[type_name]
	if shown {
		hidden -= {part}
	} else {
		hidden += {part}
	}
	if hidden == {} {
		if key, _ := delete_key(&_hidden, type_name); key != "" do delete(key)
		return
	}
	// In place: an assignment would store the caller's (maybe temp) key.
	if v, ok := &_hidden[type_name]; ok {
		v^ = hidden
	} else {
		_hidden[strings.clone(type_name)] = hidden
	}
}

// The type names that hide `part`, for saving (temp).
gizmo_types_hiding :: proc(part: Gizmo_Part) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for name, hidden in _hidden do if part in hidden do append(&out, name)
	return out
}

// The channels the scene view draws: gizmos and icons (.Editor) only with its
// Gizmos toggle on.
scene_gizmo_channels :: proc() -> bit_set[engine.Gizmo_Channel] {
	return {.Game, .Editor, .Tools} if scene_gizmos else {.Game, .Tools}
}

@(phase={key=engine.Phase.EditorInit, order=1, mode=Editor})
gizmo_settings_install :: proc() {
	view_menu_add_dynamic("Scene", "Gizmo Settings", _draw_gizmo_settings, order = 1)
	view_menu_add_dynamic("Game", "Gizmo Settings", _draw_gizmo_settings, order = 1)
}

// The Gizmo Settings submenu: the icon size, then a row per component type
// with its icon and gizmo checkboxes. Checkboxes leave the menu open.
@(private = "file")
_draw_gizmo_settings :: proc() {
	im.TextUnformatted("Icon Size")
	im.SameLine()
	widgets.slider_float("##gizmo_icon_px", &handles.icon_px, 12, 64, "%.0f px", 140)
	im.Separator()
	flags := im.TableFlags_SizingFixedFit | im.TableFlags_RowBg
	if im.BeginTable("##gizmo_types", 3, flags) {
		im.TableSetupColumn("Icon")
		im.TableSetupColumn("Gizmo")
		im.TableSetupColumn("Component")
		im.TableHeadersRow()
		for name in __gizmo_types {
			im.PushID(strings.clone_to_cstring(name, context.temp_allocator))
			shown := gizmo_type_shown(name)
			im.TableNextRow()
			im.TableNextColumn()
			icon := .Icon in shown
			if im.Checkbox("##icon", &icon) do gizmo_type_set(name, .Icon, icon)
			im.TableNextColumn()
			gizmo := .Gizmo in shown
			if im.Checkbox("##gizmo", &gizmo) do gizmo_type_set(name, .Gizmo, gizmo)
			im.TableNextColumn()
			im.TextUnformatted(strings.clone_to_cstring(gizmo_type_label(name), context.temp_allocator))
			im.PopID()
		}
		im.EndTable()
	}
}

// A type name in words: "BoxCollider2D" reads "Box Collider 2D" (temp).
gizmo_type_label :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	prev: rune
	for r, i in name {
		upper := r >= 'A' && r <= 'Z'
		digit := r >= '0' && r <= '9'
		prev_lower := prev >= 'a' && prev <= 'z'
		prev_letter := prev_lower || (prev >= 'A' && prev <= 'Z')
		if i > 0 && ((upper && prev_lower) || (digit && prev_letter)) do strings.write_byte(&b, ' ')
		strings.write_rune(&b, r)
		prev = r
	}
	return strings.to_string(b)
}
