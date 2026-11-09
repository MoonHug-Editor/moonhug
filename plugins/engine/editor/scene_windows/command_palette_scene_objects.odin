package scene_windows

// The command palette's scene objects mode (docs/core/Keymaps.md).

import "core:fmt"
import "core:path/filepath"
import engine "moonhug:packages/engine"
import "moonhug:editor/command_palette"
import "moonhug:editor/session"

// Every object of the open scenes by name, in hierarchy order, with its
// Hierarchy glyph, its scene and parents beside it. Enter selects the object, reveals it in the Hierarchy
// and frames it in the Scene window.
@(command_palette_mode={name="Scene Objects", prefix="@", run=command_palette_scene_objects_run, shortcut="Ctrl+Shift+O", help="Finds an object of the open scenes, selects it and frames it"})
command_palette_scene_objects :: proc(query: string, rows: ^[dynamic]command_palette.Row) {
	ts := command_palette.terms(query)
	w := engine.ctx_world()
	sm := engine.ctx_scene_manager()
	for i in 0 ..< sm.count {
		scene := sm.loaded[i]
		if scene == nil || !engine.sm_scene_is_valid(scene) do continue
		name := filepath.stem(scene.path) if scene.path != "" else "Untitled"
		host_ns := engine.scene_nested_hosts_map(scene)
		_command_palette_objects_walk(w, scene, engine.Transform_Handle(scene.root.handle), name, ts, host_ns, rows)
	}
}

// Lists the children of `tH` that match, then their children: `path` is
// where they sit, the scene name and the parents' names. A parent's path is
// built once for all its children, so a leaf costs no string.
@(private = "file")
_command_palette_objects_walk :: proc(w: ^engine.World, scene: ^engine.Scene, tH: engine.Transform_Handle, path: string, ts: []string, host_ns: map[engine.Transform_Handle]^engine.NestedScene, rows: ^[dynamic]command_palette.Row) {
	t := engine.pool_get(&w.transforms, engine.Handle(tH))
	if t == nil do return
	// A nested scene's objects resolve their children in that scene, as the
	// Hierarchy draws them.
	sc := t.scene if t.scene != nil else scene
	for child in t.children {
		ch, ok := engine.scene_ref_resolve_transform(sc, child, tH)
		if !ok do continue
		c := engine.pool_get(&w.transforms, engine.Handle(ch))
		if c == nil do continue
		if command_palette.matches(c.name, ts) {
			icon := string(hierarchy_row_icon(sc, ch, host_ns))
			append(rows, command_palette.Row{label = c.name, detail = path, icon = icon, data = new_clone(ch, context.temp_allocator)})
		}
		if len(c.children) > 0 do _command_palette_objects_walk(w, sc, ch, fmt.tprintf("%s/%s", path, c.name), ts, host_ns, rows)
	}
}

command_palette_scene_objects_run :: proc(row: command_palette.Row) {
	tH := (^engine.Transform_Handle)(row.data)^
	if !engine.pool_valid(&engine.ctx_world().transforms, engine.Handle(tH)) do return
	session.select_only(tH)
	// The Hierarchy opens its ancestors and scrolls to it.
	engine.inspector_request_select(tH)
	session.frame_selected()
}
