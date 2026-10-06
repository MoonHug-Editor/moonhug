package gizmos

// Gizmo visibility settings (docs/core/Gizmos.md): the scene view's Gizmos
// toggle and, per component type, which parts of its gizmo hook show.
//
// - The scene view's Gizmos toggle shows or hides every gizmo and icon in it.
//   Handles and the transform gizmo stay in the scene view either way, and so
//   do gameplay shapes (.Game).
// - Per component type with an @(on_draw_gizmos) hook, whether its icon and
//   its gizmo show. The gizmo dispatcher applies them around each hook
//   (with_icons, with_shapes), so hook code never checks them.
// - The editor draws the Gizmo Settings menu over this state and persists it
//   per type by name: type keys are not stable across builds.

import "base:runtime"
import "core:strings"
import core "moonhug:host/core"

Gizmo_Part :: enum {
	Icon,
	Gizmo,
}

// The scene view's Gizmos toggle. The game view's is the editor's game_gizmos.
@(view_menu={view="Scene", label="Gizmos"})
scene_gizmos := true

// The component types with an @(on_draw_gizmos) hook, for the Gizmo Settings
// rows. The scene tools set it from their generated dispatcher at start.
gizmo_types: []string

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
scene_gizmo_channels :: proc() -> bit_set[core.Gizmo_Channel] {
	return {.Game, .Editor, .Tools} if scene_gizmos else {.Game, .Tools}
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
