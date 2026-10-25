---
title: "Views"
description: "Editor views and the attributes that extend them: windows, view menus, tab bar widgets, the asset a view edits and saving, scene view overlays, the toolbar"
order: 110
tags: ["views", "windows", "attributes", "save", "editor"]
path: editor
---

A view is a dockable editor window: the built-in ones (Scene, Game, Hierarchy, Inspector, Project, Console and the rest) and the windows a plugin declares. Plugins extend views through attributes, which the prebuild turns into registrations in the editor. The view itself needs no code for any of them.

## View ids

Every view's imgui title is `"<icon> <label>###<id>"`. imgui keys the window, its dock place and the saved layout on the id after `###`, and every attribute on this page names a view by that id: `"Scene"`, `"Animation"`, `"shader_graph"`. So the icon and the label can change, a star appears while the view's asset has unsaved changes, and the tab never moves.

## Editor windows

A plugin declares a dockable window with `@(editor_window)` and opens it by id:

```odin
import wnd "moonhug:editor/window"

@(editor_window={id="physics2d", title="Physics 2D", icon="TUNE", width=420, height=240})
draw_physics_debug :: proc() {
    // window CONTENT only: Begin/End, the close button and the open flag
    // belong to the host
}

@(menu_item={path="Window/Physics 2D", shortcut=""})
open_physics_debug :: proc() {
    wnd.open("physics2d")
}
```

- `title` defaults to the id. `icon` names a Material Symbols glyph from `editor/icons` without the `ICON_MD_` prefix (default `EXTENSION`). `width` and `height` are the first-shown size, applied only while imgui.ini has no entry for the id. Once the user resizes or docks it, imgui.ini wins.
- `wnd.open` focuses the window if it is already open. Any code can call it, a button or a context menu as well as a menu item.
- The open list lasts for the process, so a window reopens from its menu after a restart. Its dock place and size persist in imgui.ini by id. `editor/imgui_ini_migrate.odin` renames `[Window][<title>]` entries to the id on startup, for layouts saved before titles carried icons.
- Declarations land in `editor/editor_windows_generated.odin` (editor_window_gen). `packages/plugin_example/editor` carries a working demo.

## Menu and tab bar

Every dock node's tab bar ends with a ⋮ button, whose menu acts on the visible view. Both attributes below land in `editor/view_chrome_generated.odin` (view_chrome_gen).

- **`@(view_menu={view, label, order, enabled, checked})`** adds an item to that menu. On a proc it is an action, on a bool variable a toggle. `label` is a path in the view's menu, so `"Display/Grid"` makes a submenu. `order`, `enabled` and `checked` work as on `@(menu_item)`. Two declarations of one label in one view stop the build. The bridge invokes them as `View/<view>/<label>` ([MCP Bridge](McpBridge.md)).
- **`@(view_tab_bar={view, order})`** adds a widget left of the ⋮ button: a proc that draws it with imgui, at a width that does not change with its state. The padlock on both inspectors is one (`editor/inspector_lock.odin`).

```odin
@(view_menu={view="Game", label="Gizmos"})
game_gizmos: bool
```

## The asset a view edits

A view that edits an asset names it with `@(view_document)` on a public proc, which returns the asset's guid, or `{}` while the view edits none. The view's tab menu then starts with Save and Discard for that asset, and its tab carries a star while the asset has unsaved changes. A locked view returns its locked asset. The attribute is optional: the Project Inspector, the Hierarchy, the Scene view and the Animation, Shader Graph and Render Pipeline windows have one, and a view without it has no Save, Discard or star on its tab.

```odin
@(view_document={view="shader_graph"})
shader_graph_view_document :: proc() -> engine.Asset_GUID {
	return _sg.guid // {} while the window edits nothing
}
```

An open document is an asset loaded for editing (`editor/session/documents.odin`): a loaded scene, or a serialized asset. An owner is the code that holds loaded copies, not a file type. There are two: the scene manager's loaded scenes, and the inspector's asset documents, which cover every serialized asset type. Every view that edits an asset shares its one document. Each owner reports what it holds when asked, so no list is kept. File/Save saves every dirty document. Import settings are not documents: they commit through Apply and go back through Revert ([Undo](Undo.md)).

- **Discard is final.** It asks first, then reads the document again from its file and purges its undo steps (`undo.purge_asset`, `undo.purge_scene`). Enter discards, Escape cancels.
- **After a save**, a hook per asset type refreshes what the file feeds (`inspector.doc_saved_register`): the Shader Graph reimports and drops its cached shader, the Render Pipeline reimports.
- **Quitting** with dirty documents asks first, through one check (`quit_gate`, `editor/quit_prompt.odin`) that File/Quit, the window's close button and Relaunch all pass. During a Relaunch, `mh` waits while the editor runs and the ready marker exists. Cancel removes the marker, so nothing launches.

A window that edits an asset keeps the asset's guid and edits its shared document (`inspector.asset_doc_get`), allocating with `inspector.doc_alloc()`. It never keeps the document pointer across frames: an undo, a redo or a Discard replaces the instance.

An editor that needs its own working copy, applied to the asset at once, also registers an owner (`session.document_owner_add`): `list` reports the copy, `save` applies it, `discard` drops it. File/Save, the quit prompt and the project window's star then cover the copy. A guid alone cannot tell the copy from the asset's shared document, so the tab menu needs more from the attribute before it can name a copy. No editor keeps a copy today.

## Scene view overlays

`@(scene_overlay={id="Tools", order=N})` on a `proc(vertical: bool)` adds an item to a scene view overlay (`editor/dock.odin`). Items sharing an id sit in one overlay and sort by order. The proc draws imgui widgets and calls `SameLine` between its own widgets when `vertical` is false.

An overlay sits in one of three kinds of place, and the user drags it between them by its grip:

- **A toolbar strip** along the left, right, top or bottom edge. A strip reserves its own space, so the view image shrinks beside it instead of being covered. A strip is only as thick as the items it holds: an overlay in a strip drops its own panel and its grip shrinks to the item height, so the strip hugs the buttons. An empty strip has zero thickness and draws nothing. The top and bottom strips take the corners and span the full width, and the side strips run between them.
- **A floating corner or side** inside the image, drawn over the render.
- **Free floating** anywhere inside the image.

While an overlay drags, every zone highlights and the one under the cursor takes an accent. The outermost band on each edge is the strip, and the floating zones sit just inside it. The top and bottom bands are taller and span the full width, taking the corners, so the side bands run only between them, the same split the drawn strips use. Placement persists per overlay in `UserSettings/editor_settings.json`.

An overlay whose items draw nothing shows no background, grip or hover, and costs its strip no space. A conditional overlay therefore vanishes with its content and returns the moment an item draws again.

A view opts in by taking the strip space before it sizes its image: `overlays_measure_bars`, then `overlay_bar_insets` for the four thicknesses, then `overlays_draw` with both the image rect and the full content rect.

## Editor toolbar

`@(toolbar={zone, order})` on a proc adds a widget to the toolbar above the dock space, in its `"left"`, `"center"` or `"right"` zone. Items sort by order inside a zone. Zones are measured by drawing their items off-screen once per frame, so an item declares no width but keeps it fixed across states. The simulate controls, the run buttons and Relaunch are registered the same way (`editor/view_toolbar.odin`).

## Game view toolbar

The Game view draws its own toolbar above its image (`editor/view_game.odin`):

- **Size**: Free Aspect fills the view, an aspect letterboxes to that ratio, and a fixed resolution renders exactly those pixels, scaled down when it does not fit. The list is built in.
- **Flip**: swaps the selected size's width and height, for portrait targets. Disabled on Free Aspect, which has no ratio to swap.
- **Scale**: zooms the rendered rect. 1x is the size's actual pixels and the maximum is 5x. The minimum is 1x, or the zoom that fits the size in the view when its pixels are larger, so the game is never cropped. Parking the slider at that floor means "match the view": the zoom follows the floor as the view resizes. A 1x button returns to actual pixels, and zoom is disabled on Free Aspect, which already fills the view.

The rendered rect is centered in the area under the toolbar. When the zoom makes it larger than the area, the area scrolls: a scrollbar appears on each axis that overflows, the rect stays centered on an axis that fits, and the mouse wheel stays the game's input, so the bars are dragged. The input viewport follows the rect as it scrolls, so game mouse coordinates stay correct at any size, scale or scroll. Size, flip and scale persist in `UserSettings/editor_settings.json`.
