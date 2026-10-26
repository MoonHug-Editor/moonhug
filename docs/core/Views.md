---
title: "Views"
description: "Editor views and the attributes that extend them: windows, view menus, tab bar widgets, workspaces, the asset a view edits and saving, scene view overlays, the toolbar"
weight: 110
tags: ["views", "windows", "workspaces", "attributes", "save", "editor"]
path: editor
---

A view is a dockable editor window. Every view except the Game view is declared with `@(editor_window)`: the Scene, Hierarchy, Project, Console, Output and History views, the two inspectors, the Animation and Playable Graph views, and every plugin window. Each one opens as copies, and every copy has its own state. The Game view exists once, since game code reads one screen size per frame. Plugins extend views through attributes, which the prebuild turns into registrations in the editor. The view itself needs no code for any of them.

## View ids

Every view's imgui title is `"<icon> <label>###<key>"`. imgui keys the window, its dock place and the saved layout on the key after `###`, so the icon and the label can change, a star appears while the view's asset has unsaved changes, and the tab never moves. A view's key is its id (`"Scene"`, `"Animation"`). A window instance opened for an asset adds the asset's guid (`"shader_graph/<guid>"`), and another plain instance adds a number (`"Inspector/2"`). Every attribute on this page names a view by its id, the key up to its first `/`, so all instances of a window share its menu and tab bar items. The procs behind those items receive the view they act for as a `session.View`, its key and its id, so each instance answers for itself. A plugin window finds its instance with `wnd.find(view.key)`. Code outside a view that needs one of its copies, such as a menu action, an asset ping or the bridge, acts on the copy opened or clicked in last (`wnd.last(id)`). A request every copy follows goes to all of them (`wnd.instances(id)`): the Hierarchy reveals and pings in each copy.

## Editor windows

A plugin declares a dockable window with `@(editor_window)` and opens it by id:

```odin
import wnd "moonhug:editor/window"

@(editor_window={id="physics2d", title="Physics 2D", icon="TUNE", width=420, height=240})
draw_physics_debug :: proc(w: ^wnd.Window) {
    // window CONTENT only: Begin/End, the close button and the open flag
    // belong to the host
}

@(menu_item={path="Window/Physics 2D", shortcut=""})
open_physics_debug :: proc() {
    wnd.open("physics2d")
}
```

- `title` defaults to the id. `icon` names a Material Symbols glyph from `editor/icons` without the `ICON_MD_` prefix (default `EXTENSION`). `width` and `height` are the first-shown size, applied only while imgui.ini has no entry for the instance. Once the user resizes or docks it, imgui.ini wins.
- A window opens as instances. `wnd.open(id)` shows its plain instance, `wnd.open(id, asset)` the instance for that asset, so two assets are edited side by side. Opening an open instance focuses it. Any code can call it, a button or a context menu as well as a menu item. `wnd.open_another(id)` opens another plain instance under the lowest free number, which is what Add Tab does when the plain instance is open.
- The draw proc receives its instance (`wnd.Window`) and keeps that instance's state in `w.data`, usually through `wnd.state(w, My_State{...})`, which makes it from the init value on first use. Window state lives there, not in globals, so a window can have several instances. State that owns memory needs a proc to free it, which the attribute's `closed` field names: `closed=draw_physics_debug_closed`. Without one, the instance frees `data` itself when it closes.
- `canvas=true` draws the window edge to edge: no window padding, no scrollbars, and the mouse wheel stays with the content. The Scene and Playable Graph views use it.
- Every instance draws in `wnd.draw_all`, after the editor's own views. A window that has to draw at a set point of the frame is drawn there with `wnd.draw(id)`, and draw_all skips it: the Scene view draws after the gizmo pass and inside the animation preview pose.
- An asset instance's tab shows the asset's name, and its tab menu offers Save and Discard for that asset, with the star while it has unsaved changes, with no `@(view_document)`. A new asset instance with nothing saved docks beside an open instance of the same window.
- The editor reopens the open instances after a restart. Each one's dock place and size persist in imgui.ini by its key. `editor/imgui_ini_migrate.odin` renames `[Window][<title>]` entries to the id on startup, for layouts saved before titles carried icons.
- Declarations land in `editor/editor_windows_generated.odin` (editor_window_gen). `packages/plugin_example/editor` carries a working demo.

## Menu and tab bar

Every dock node's tab bar ends with a ⋮ button, whose menu acts on the visible view. It ends with Add Tab, which lists every view by name and opens a new one in that node: the window's plain instance, or a numbered one when the plain one is open. The Game view opens there when it is closed, and is focused where it is when open. Both attributes below land in `editor/view_chrome_generated.odin` (view_chrome_gen).

- **`@(view_menu={view, label, order, enabled, checked})`** adds an item to that menu. On a `proc(view: session.View)` it is an action, on a bool variable a toggle. `label` is a path in the view's menu, so `"Display/Grid"` makes a submenu. `order`, `enabled` and `checked` work as on `@(menu_item)`, and the predicates take the view too. A toggle's bool is shared by every instance of the view. Two declarations of one label in one view stop the build. The bridge invokes them as `View/<view>/<label>` ([MCP Bridge](McpBridge.md)).
- **`@(view_tab_bar={view, order})`** adds a widget left of the ⋮ button: a `proc(view: session.View)` that draws it with imgui for that view, at a width that does not change with its state. The padlock is one: each inspector instance has its own lock (`editor/inspector_lock.odin`).

```odin
@(view_menu={view="Game", label="Gizmos"})
game_gizmos: bool
```

## Maximize

Window/Maximize View (Shift+Space) makes the view under the mouse fill the dock area, with its tab, its tab-bar widgets and its ⋮ menu. The same shortcut puts it back in its dock node, at its tab's place, and closing it does too. The shortcut does nothing while a text field is being typed in.

- Every other docked view hides and stays docked: the main dockspace keeps its nodes alive and shows nothing (`ImGuiDockNodeFlags_KeepAliveOnly`), and a second dockspace over the same area shows the view (`editor/maximize.odin`).
- A hidden placeholder keeps the node the view left. imgui deletes a node when its last window leaves, and its split would close.
- imgui.ini is written first and not saved while a view is maximized, so quitting then keeps the layout as it was.
- A docked view and a floating one maximize alike. A view in a Workspace view's frame has no window of its own: it gets one while maximized, its frame says it is away, and it goes back to its frame after, brought into view there.

## Workspaces

The Workspace view (Window/General/Workspace) is a canvas you pan, holding frames. A frame is a group of view tabs at a rectangle, with the chrome a dock node gives a view: its tab-bar widgets and its ⋮ menu. The canvas has no zoom. A view draws its contents the same way in a frame as in its own window, so every view works in a workspace with no code for it.

- Drag the canvas background to pan. Drag a frame's grip to move its chain, its right or bottom border to resize it.
- Frames form chains, one level deep: a parent frame and its child frames. A view opened from a view in a frame, such as a shader graph double-clicked in a Project frame, opens in a new child frame of that frame. A child frame sits 30 px right of its parent, 20 px under the children before it, linked to it by a curve, and moves with it. Opening a view that is already in a frame shows it there: its tab is picked and its frame brought into view. A frame's ⋮ menu adds a view in a new child frame (Add Child), sets the frame's parent (Set Parent, its own children come along), or unparents it (Unparent). A frame that goes leaves its children where they are, each heading its own chain.
- Chains keep 40 px apart. When one grows or is dropped onto another, the other moves away by the shortest way. The chain being dragged or worked in stays.
- Add View opens a new instance of a view in a new frame. A frame's ⋮ menu has the view's own items, Move to Dock, which gives the view back its own window, and Add Tab. A docked view's tab menu has Move to Workspace, listing the workspaces the open Workspace views show.
- The toolbar's dropdown lists every workspace every provider holds now. New makes one in a provider of your choice. The view's ⋮ menu renames and deletes the shown one.
- One Workspace view shows a workspace at a time: the first one open that picked it. In another Workspace view the dropdown greys it out, and a view that picked it before says it is open elsewhere.
- The mini-map shows every frame and the visible area. Click or drag in it to go there, or grab the visible area to move it. The map button at the toolbar's right end shows and hides it. Hold Ctrl or Cmd over it and drag to move it, and drag any of its corners to resize it. The view's ⋮ menu (Mini-map) attaches it to a corner or a side of the canvas, top right by default, and resets its place and size. While the mouse is over the map, nothing in the frames under it takes the mouse: no splitter, resize border or button reacts through it.

A workspace (`editor/workspace`) has a unique id, a name, its pan and its frames. A frame has an id, never reused in its workspace, the id of the frame it is chained to, its rect and its views, named by window instance key (`Console/2`, `shader_graph/<guid>`), so its views reopen from it. `workspace.layout` places chained frames and parts chains, and `workspace.fix` makes whatever a provider loads valid. Workspaces come from providers: each one lists the workspaces it holds now, saves one after a change, makes and deletes them. User settings and project settings are built in, each in its own `workspaces.json`. A plugin adds a provider with `workspace.provider_add`, for example one that keeps workspaces in a scene: while the scene is open its workspaces are in the dropdown, and when it closes their ids are gone from it. Each Workspace view copy remembers the id of the workspace it shows and its mini-map's place (UserSettings/workspace_views.json), and says the workspace is not open while no provider holds it. The package needs no engine, so workspaces work with no plugins.

A frame's views are window instances the Workspace view hosts (`wnd.host_open(key, host)`). A hosted instance never draws as a window of its own, is left out of the saved layout (its workspace saves it), and its host draws its contents with `wnd.draw_content`. `wnd.host_release` gives it back its own window. Closing the Workspace view closes its hosted views. The registry asks `wnd.host_hook` when `wnd.open` makes a window while a hosted instance draws, or shows one that is hosted. The Workspace view's hook chains the new window to the opener's frame and reveals a hosted one, so a view needs no code to open windows into a workspace.

Each frame draws in its own imgui child window. A view that takes keys while focused checks `im.IsWindowFocused({.ChildWindows})`, so it is focused in its own frame and not in every frame of the workspace. `FocusedFlags_RootAndChildWindows` would make every view in a workspace take keys at once.

## The asset a view edits

A view whose asset changes while it stays open names it with `@(view_document)` on a public proc, which takes the view and returns the asset's guid, or `{}` while the view edits none. The view's tab menu then starts with Save and Discard for that asset, and its tab carries a star while the asset has unsaved changes. A locked view returns its locked asset. The Project Inspector and the Animation window have one. A window instance opened for an asset needs none, as the Shader Graph and Render Pipeline windows show, and a view with neither has no Save, Discard or star on its tab.

```odin
@(view_document={view="Animation"})
animation_view_document :: proc(view: session.View) -> engine.Asset_GUID {
	doc, _ := _pv_doc()
	return doc.guid if doc != nil else {} // the selected clip, {} for none
}
```

An open document is an asset loaded for editing (`editor/session/documents.odin`): a loaded scene, a serialized asset, or an editor's working copy. An owner is the code that holds loaded copies, not a file type. There are three: the scene manager's loaded scenes, the inspector's asset documents, which cover every serialized asset type, and the inspector's working copies (below). Every view that edits an asset shares its one document, unless it works on a copy. Each owner reports what it holds when asked, so no list is kept. File/Save saves every dirty document. Import settings are not documents: they commit through Apply and go back through Revert ([Undo](Undo.md)).

- **Discard is final.** It asks first, then reads the document again from its file and purges its undo steps (`undo.purge_asset`, `undo.purge_scene`). Enter discards, Escape cancels.
- **After a save**, a hook per asset type refreshes what the file feeds (`inspector.doc_saved_register`): the Shader Graph reimports and drops its cached shader, the Render Pipeline reimports.
- **Quitting** with dirty documents asks first, through one check (`quit_gate`, `editor/quit_prompt.odin`) that File/Quit, the window's close button and Relaunch all pass. During a Relaunch, `mh` waits while the editor runs and the ready marker exists. Cancel removes the marker, so nothing launches.

A window that edits an asset keeps the asset's guid and edits its shared document (`inspector.asset_doc_get`), allocating with `inspector.doc_alloc()`. It never keeps the document pointer across frames: an undo, a redo or a Discard replaces the instance.

An editor that applies its edits all at once works on a copy instead (`editor/inspector/asset_doc_copies.odin`). The Sprite Editor does this with a texture's slices.

- `h := inspector.asset_doc_copy_open(path, kind, view)` loads a copy of what the editor edits from disk: the asset's file (`.File`) or its import settings, the .meta (`.Import_Settings`). `view` is the key of the view that holds it. The texture or model itself is never touched.
- `inspector.asset_doc_copy(h)` gives the copy each frame. Undo replaces its value, so the editor keeps the handle and fetches the value through it.
- Edits recorded on the copy become steps on the one undo queue, with no code in the editor. Each step names the copy by its handle, so Ctrl+Z changes only the copy.
- `asset_doc_copy_apply(h)` writes the copy to the file, and the asset's shared document follows. `asset_doc_copy_revert(h)` goes back to the file as one undo step. `asset_doc_copy_discard(h)` drops the unapplied edits and their steps. `asset_doc_copy_close(h)` frees the copy and its steps.
- Until Apply nothing else sees the copy: the Project Inspector shows the file as it is.
- The copy is a document of the view that holds it. Its tab carries the star, the tab menu's Save applies it and Discard drops its edits, File/Save and the quit prompt cover it, and closing the view with unapplied edits asks Apply, Discard or Cancel (`editor/view_close_prompt.odin`).

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
