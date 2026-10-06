package editor

// The Gizmo Settings menu (docs/core/Gizmos.md) in the scene and game views:
// the icon size, and per component type with an @(on_draw_gizmos) hook
// whether its icon and its gizmo show. The state lives in host/gizmos
// (settings.odin), the editor persists it.

import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:host/gizmos"
import "moonhug:editor/handles"
import "moonhug:editor/widgets"

@(phase={key=core.Phase.EditorInit, order=1, mode=Editor})
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
		for name in gizmos.gizmo_types {
			im.PushID(strings.clone_to_cstring(name, context.temp_allocator))
			shown := gizmos.gizmo_type_shown(name)
			im.TableNextRow()
			im.TableNextColumn()
			icon := .Icon in shown
			if im.Checkbox("##icon", &icon) do gizmos.gizmo_type_set(name, .Icon, icon)
			im.TableNextColumn()
			gizmo := .Gizmo in shown
			if im.Checkbox("##gizmo", &gizmo) do gizmos.gizmo_type_set(name, .Gizmo, gizmo)
			im.TableNextColumn()
			im.TextUnformatted(strings.clone_to_cstring(gizmos.gizmo_type_label(name), context.temp_allocator))
			im.PopID()
		}
		im.EndTable()
	}
}
