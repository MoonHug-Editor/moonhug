---
title: "Windows"
description: "Editor windows and the attributes that extend them: window menus, tab bar widgets, workspaces, the asset a window edits and saving, Scene window overlays, the toolbar"
weight: 110
tags: ["windows", "workspaces", "attributes", "save", "editor"]
path: editor
---

Every editor window except the Game window is declared with `@(editor_window)`: the Scene, Hierarchy, Project, Console, Output and History windows, the two inspectors, the Animation and Playable Graph windows, and every plugin window. Each one opens as copies, and every copy has its own state. The Game window exists once, since game code reads one screen size per frame. Plugins extend windows through attributes, which the prebuild turns into registrations in the editor. The window itself needs no code for any of them.

## Window ids

Every window's imgui title is `"<icon> <label>###<key>"`. imgui keys the window, its dock place and the saved layout on the key after `###`, so the icon and the label can change, a star appears while the window's asset has unsaved changes, and the tab never moves. A window's key is its id (`"Scene"`, `"Animation"`). A window instance opened for an asset adds the asset's guid (`"shader_graph/<guid>"`), and another plain instance adds a number (`"Inspector/2"`). Every attribute on this page names a window by its id, the key up to its first `/`, so all instances of a window share its menu and tab bar items. The procs behind those items receive the window they act for as a `session.Window_Ref`, its key and its id, so each instance answers for itself. A plugin window finds its instance with `wnd.find(window.key)`. Code outside a window that needs one of its copies, such as a menu action, an asset ping or the bridge, acts on the copy opened or clicked in last (`wnd.last(id)`). A request every copy follows goes to all of them (`wnd.instances(id)`): the Hierarchy reveals and pings in each copy.

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
- A window opens as instances. `wnd.open(id)` shows its plain instance, `wnd.open(id, asset)` the instance for that asset, so two assets are edited side by side. Opening an open instance focuses it. Any code can call it, a button or a context menu as well as a menu item. `wnd.open_another(id)` opens another plain instance under `id/<n>` with a random number, which is what Add Tab does when the plain instance is open. A key is never handed out twice, so what is saved under one, a workspace frame's tab, a window lock, a dock place, belongs to that instance alone, in every project a shared workspace is seen from. At startup the editor drops the imgui.ini entries of copies that are gone for good (`editor/imgui_ini_migrate.odin`).
- The draw proc receives its instance (`wnd.Window`) and keeps that instance's state in `w.data`, usually through `wnd.state(w, My_State{...})`, which makes it from the init value on first use. Window state lives there, not in globals, so a window can have several instances. State that owns memory needs a proc to free it, which the attribute's `closed` field names: `closed=draw_physics_debug_closed`. Without one, the instance frees `data` itself when it closes.
- `wnd.state(w, My_State{...}, saved = true)` saves the state with the window (see Saved state).
- `canvas=true` draws the window edge to edge: no window padding, no scrollbars, and the mouse wheel stays with the content. The Scene and Playable Graph windows use it.
- Every instance draws in `wnd.draw_all`, after the editor's own windows. A window that has to draw at a set point of the frame is drawn there with `wnd.draw(id)`, and draw_all skips it: the Scene window draws after the gizmo pass and inside the animation preview pose. A Scene window in a Workspace window's frame draws with its Workspace window, after the pose is restored, so its render runs at the set point instead (`scene_windows_render_hosted`), at the size its frame gave it last frame, and its frame shows that render.
- An asset instance's tab shows the asset's name, and its tab menu offers Save and Discard for that asset, with the star while it has unsaved changes, with no `@(window_document)`. A new asset instance with nothing saved docks beside an open instance of the same window.
- The editor reopens the open instances after a restart. Each one's dock place and size persist in imgui.ini by its key. `editor/imgui_ini_migrate.odin` renames `[Window][<title>]` entries to the id on startup, for layouts saved before titles carried icons.
- Declarations land in `editor/editor_windows_generated.odin` (editor_window_gen). `packages/plugin_example/editor` carries a working demo.

## Menu and tab bar

Every dock node's tab bar ends with a ⋮ button, whose menu acts on the visible window. It ends with Add Tab, which lists every window by name and opens a new one in that node: the window's plain instance, or a numbered one when the plain one is open. The Game window opens there when it is closed, and is focused where it is when open. Both attributes below land in `editor/window_chrome_generated.odin` (window_chrome_gen).

- **`@(window_menu={window, label, order, enabled, checked})`** adds an item to that menu. On a `proc(window: session.Window_Ref)` it is an action, on a bool variable a toggle. `label` is a path in the window's menu, so `"Display/Grid"` makes a submenu. `order`, `enabled` and `checked` work as on `@(menu_item)`, and the predicates take the window too. A toggle's bool is shared by every instance of the window. Two declarations of one label in one window stop the build. The bridge invokes them as `Window Menu/<window>/<label>` ([MCP Bridge](McpBridge.md)).
- **`@(window_tab_bar={window, order})`** adds a widget left of the ⋮ button: a `proc(window: session.Window_Ref)` that draws it with imgui for that window, at a width that does not change with its state. The window locks are not one of these: a window declares one with `lock` on `@(editor_window)` (below).

```odin
@(window_menu={window="Game", label="Gizmos"})
game_gizmos: bool
```

### Window locks

A window declares a padlock with `lock` on its `@(editor_window)`: `lock="instance"` gives each instance its own lock, `lock="shared"` one lock all its instances share, for a window whose instances show one state, as the Animation window's copies share one preview. The shell draws the padlock first in the window's tab bar, the same for every such window (`editor/window_lock.odin`). The Inspector, the Project Inspector and the Animation window have one.

A plugin window with a lock:

```odin
import wnd "moonhug:editor/window"
import "moonhug:editor/session"

@(editor_window={id="my_view", title="My Window", lock="instance"})
my_view_draw :: proc(w: ^wnd.Window) {
    if session.window_lock_missing_note(w.key) do return
    tH := session.window_object(w.key) // the selection, or what the lock holds
    // draw tH
}
```

- Locking takes the selection as it is now, both sets: the selected objects, or the ones kept while assets are selected, and the selected assets with their sub-asset ids, or the ones kept while objects are selected. With nothing selected the window stays unlocked.
- A window reads what to show through the session package, locked or not: `session.window_objects` and `session.window_object` for scene objects, `session.window_assets` and `session.window_asset` for assets. Unlocked these are the selection. Locked they are what the lock holds.
- Every read takes the instance's key, `w.key`, for both kinds of lock. A shared lock is found from it.
- A window that reads the selection itself, through `session.selection`, `session.active`, `session.project_active` or `engine.inspector_inspected_selection`, gets a padlock that changes nothing. All of its targets come from the `session.view_*` reads.
- A lock holds references, not handles: an object as its scene's asset guid and its local id, an asset as its guid and sub-asset id. A locked target that does not resolve now is missing, not gone: its scene is closed or it was deleted. The lock stays, the window shows `session.window_lock_missing_note` where its target would be, and shows the target again when it is back, after an undo or when the scene reopens.
- The same local id never names another object: the engine mints ids at random among 2^63 and checks the live ones, and undo restores an object with its own id.
- A lock goes when the window is unlocked, or when its window closed and cannot come back under its key. While it can, the lock waits, and the window is locked as it was when Reopen Closed brings it back or the workspace that hosted it shows it again. A plain instance opened fresh from the menu starts unlocked. A lock waiting for its window, restored after a restart or in a workspace not hosted yet, waits as long as it takes.
- Locks survive a restart. A docked or floating window's lock is saved in the user settings, in the window's record of the `windows` list, and taken up once the reopened scenes load (`editor/selection_persist.odin`). A lock waiting for a window only Reopen Closed can bring back is not saved, since the closed list does not outlive the session.
- The lock of a window in a workspace frame is saved in its workspace (`workspace.Saved_Window`), so it goes where the workspace goes: another project, a restart, a source that drops the workspace and brings it back. The Workspace window keeps the saved lock equal to the window's (`workspace_locks_sync`), and a window a frame opens takes it (`workspace_lock_take`). A target that is not in this project shows as missing, as any lock's does.
- A plugin window gets all of this from the attribute and the `session.window_*` reads. It draws no padlock and keeps no lock state of its own.
- The Project Inspector reads its asset the same way: each instance shows `session.window_asset` for its key, the project selection or its lock's asset, and shows nothing when that names nothing it can show (`project_inspectors_follow` in `editor/window_project.odin`).

### Saved state

A window whose state should come back asks for it with `saved`:

```odin
@(private = "file")
_My_Window :: struct {
    show_hidden: bool,
    split_ratio: f32,
    hovered_row: int `json:"-"`, // not saved
}

@(editor_window={id="my_view", title="My Window"})
my_window_draw :: proc(w: ^wnd.Window) {
    v := wnd.state(w, _My_Window{split_ratio = 0.6}, saved = true)
}
```

- The state struct is saved as it is, through the json marshaller. A field that must not be saved carries `json:"-"`: a pointer, a handle, a cache, a text buffer.
- It is saved per instance, under the instance's key. A new instance starts from the init value with what was saved for its key read over it, so a field added later keeps its init value.
- A reopened instance has its whole struct back, the unsaved fields too: the registry keeps the struct of a closed instance while the instance can come back under its key (Reopen Closed, a workspace that shows it again).
- A `closed` proc of a window with saved state either leaves `w.data` as it is, and the struct is kept, or frees it and sets `w.data` to nil, and the instance comes back from its saved fields alone. A saved field that owns memory needs the second form.
- What is saved for an instance goes when it is closed and cannot come back under its key. The plain instance is the exception: a window opened again from the menu shows as it was left, after a restart too.
- The state survives a restart. A docked or floating window's is in the user settings, in the window's record of the `windows` list, beside its lock. The state of a window in a workspace frame is in its workspace, so it goes where the workspace goes. The Workspace window takes it from the open window while the mouse is up (`workspace_states_sync`) and gives it to a window a frame opens (`workspace_state_give`).
- The registry writes no file itself (`window/window_saved.odin`): `wnd.saved_text` and `wnd.saved_set` are what the user settings and the workspaces save and give back.
- The Console, Output and History windows save their state this way.

## Maximize

Shift+Space makes the window under the mouse fill the dock area, with its tab, its tab-bar widgets and its ⋮ menu, and Maximize in a window's ⋮ menu does it for that window. The same shortcut or menu item puts it back in its dock node, at its tab's place, and closing it does too. There is no main menu item: a menu is clicked with the mouse away from every window. The shortcut does nothing while a text field is being typed in.

- Every other docked window hides and stays docked: the main dockspace keeps its nodes alive and shows nothing (`ImGuiDockNodeFlags_KeepAliveOnly`), and a second dockspace over the same area shows the window (`editor/maximize.odin`).
- A hidden placeholder keeps the node the window left. imgui deletes a node when its last window leaves, and its split would close.
- imgui.ini is written first and not saved while a window is maximized, so quitting then keeps the layout as it was.
- A docked window and a floating one maximize alike. A window in a Workspace window's frame has no window of its own: it gets one while maximized, its frame says it is away, and it goes back to its frame after, brought into view there. When its Workspace window closed meanwhile, it keeps its own window.

## Workspaces

The Workspace window (Window/General/Workspace) is a canvas you pan, holding frames. A frame is a group of window tabs at a rectangle, with the chrome a dock node gives a window: its tab-bar widgets and its ⋮ menu. The canvas has no zoom. A window draws its contents the same way in a frame as in its own window, so every window works in a workspace with no code for it.

- Drag the canvas background to pan. Drag a frame's grip to move its whole tree, its right or bottom border to resize it. A child frame's up and down arrows, beside its grip, move it one place among its parent's children, or with Shift to the top or the bottom.
- Drag a tab up or down out of its frame's tab bar to move it: onto another frame it joins that frame's tabs, onto empty canvas it gets a frame of its own there. A frame's only tab dragged onto empty canvas moves its frame there with its subtree, out of its parent's tree. Along the bar a drag reorders the tabs. The drag's payload is the window's key (`wnd.TAB_PAYLOAD`, read with `wnd.tab_payload_key`), so any drop target can read it.
- Frames form trees of any depth: any frame can be a parent, and a child can have children of its own. A window opened from a window in a frame, such as a shader graph double-clicked in a Project frame, opens in a new child frame of that frame. Each child is linked to its parent by a curve and moves with it.
- The layout places every tree from its root. A frame's children sit 30 px right of its right edge, stacked down from its top in sibling order. Each child takes the height of its subtree: its own height, or its children's stacked height when that is more. 20 px part one child's subtree from the next, with no other gaps.
- Opening a window that is already in a frame shows it there: its tab is picked and its frame brought into view.
- A frame's ⋮ menu adds a window in a new child frame (Add Child), sets the frame's parent (Set Parent, its subtree comes along), or unparents it (Unparent), which makes it the root of its own tree.
- Set Parent is a menu of the trees. A frame with no children is an item that parents to it. A frame with children is a submenu: its first item, `+ <frame>`, parents to it, then come its children the same way. The frame itself and the frames below it are not in the menu, so no tree loops back on itself. The current parent is checked.
- A frame that goes hands its children to its parent: they take its place among its siblings, in their own order, so the tree closes up. The children of a root that goes head their own trees.
- Trees keep 40 px apart, each measured by the box around all its frames. When one grows or is dropped onto another, the other moves away by the shortest way. The tree being dragged or worked in stays.
- Add Window opens a new instance of a window in a new frame. A frame's ⋮ menu has the window's own items, Move to Dock, which gives the window back its own window, and Add Tab. A docked window's tab menu has Move to Workspace, listing the workspaces the open Workspace windows show.
- The toolbar's dropdown lists every workspace every provider holds now. New makes one in a provider of your choice. The window's ⋮ menu renames and deletes the shown one, and Save In moves it to another provider, keeping its id, so every Workspace window showing it goes on showing it.
- One Workspace window shows a workspace at a time: the first one open that picked it. In another Workspace window the dropdown greys it out, and a window that picked it before says it is open elsewhere.
- The mini-map shows every frame and the visible area. Click or drag in it to go there, or grab the visible area to move it. The map button at the toolbar's right end shows and hides it. Hold Ctrl or Cmd over it and drag to move it, and drag any of its corners to resize it. The window's ⋮ menu (Mini-map) attaches it to a corner or a side of the canvas, top right by default, and resets its place and size. While the mouse is over the map, nothing in the frames under it takes the mouse: no splitter, resize border or button reacts through it.

A workspace (`editor/workspace`) has a unique id, a name, its pan, its frames and what its windows save: their locks and their saved state. A frame has an id, never reused in its workspace, the id of its parent frame (0 for a root), its rect and its windows, named by window instance key (`Console/2`, `shader_graph/<guid>`), so its windows reopen from it. `workspace.layout` places the frames of each tree and parts the trees, `workspace.chain` sets a parent and refuses one that is the frame or below it, `workspace.subtree` lists a frame and every frame below it, parent before child, and `workspace.fix` makes whatever a provider loads valid: a missing parent is dropped and a saved cycle is broken. Workspaces come from providers: each one lists the workspaces it holds now, saves one after a change, makes and deletes them, and can let one go (`detach`) or take one in (`adopt`), which `workspace.move_to` uses. User settings and project settings are built in, each in its own `workspaces.json`. A `workspaces.json` that does not parse shows no workspaces and is never written over: an error in the Console names it, and saving stays off until it is repaired. A plugin adds a provider with `workspace.provider_add`, for example one that keeps workspaces in a scene: while the scene is open its workspaces are in the dropdown, and when it closes their ids are gone from it. Each Workspace window copy remembers the id of the workspace it shows and its mini-map's place (UserSettings/workspace_windows.json), and says the workspace is not open while no provider holds it. The package needs no engine, so workspaces work with no plugins.

A frame's windows are window instances the Workspace window hosts (`wnd.host_open(key, host)`). A hosted instance never draws as a window of its own, is left out of the saved layout (its workspace saves it), and its host draws its contents with `wnd.draw_content`. `wnd.host_release` gives it back its own window. Closing the Workspace window closes its hosted windows.

- A host claims every window it holds with `host_open` each frame, whether it draws it or not: a tab in the back, or a frame scrolled out of view.
- One host at a time: while a host claims a window, another host's `host_open` gets nil (`wnd.host_held_elsewhere`). When two workspaces name the same window, the Workspace window that took it first shows it, and the other one's tab says it is open in another Workspace window.
- A workspace is closed, loaded, or shown. Loaded, its windows exist with their documents and unapplied edits, claimed every frame by the Workspace window that loaded it, and drawn only while it is the one shown. Showing another workspace keeps it loaded. Unload Workspace in the window's ⋮ menu closes its windows without saving, after one question naming the documents with unapplied edits. Closing the Workspace window, or deleting a workspace, unloads the same way. A hosted window no host claimed during a frame closes at the end of `wnd.draw_all`, unless its host did not draw at all (its tab is behind another one), so a window is never hosted and drawn by nobody, and a workspace changes no layout outside its own window. Move to Dock is the one way a window leaves a workspace for the dock.

Each frame draws in its own imgui child window. A window that takes keys while focused checks `im.IsWindowFocused({.ChildWindows})`, so it is focused in its own frame and not in every frame of the workspace. `FocusedFlags_RootAndChildWindows` would make every window in a workspace take keys at once.

## The asset a window edits

A window whose asset changes while it stays open names it with `@(window_document)` on a public proc, which takes the window and returns the asset's guid, or `{}` while the window edits none. The window's tab menu then starts with Save and Discard for that asset, and its tab carries a star while the asset has unsaved changes. A locked window returns its locked asset. The Project Inspector and the Animation window have one. A window instance opened for an asset needs none, as the Shader Graph and Render Pipeline windows show, and a window with neither has no Save, Discard or star on its tab.

```odin
@(window_document={window="Animation"})
animation_window_document :: proc(window: session.Window_Ref) -> engine.Asset_GUID {
	doc, _ := _pv_doc()
	return doc.guid if doc != nil else {} // the selected clip, {} for none
}
```

An open document is an asset loaded for editing (`editor/session/documents.odin`): a loaded scene, a serialized asset, or an editor's working copy. An owner is the code that holds loaded copies, not a file type. There are three: the scene manager's loaded scenes, the inspector's asset documents, which cover every serialized asset type, and the inspector's working copies (below). Every window that edits an asset shares its one document, unless it works on a copy. Each owner reports what it holds when asked, so no list is kept. File/Save saves every dirty document. Import settings are not documents: they commit through Apply and go back through Revert ([Undo](Undo.md)).

- **Discard is final.** It asks first, then reads the document again from its file and purges its undo steps (`undo.purge_asset`, `undo.purge_scene`). Enter discards, Escape cancels.
- **After a save**, a hook per asset type refreshes what the file feeds (`doc_on_saved_<Type>` with `@(doc_on_changed={type=T})` and `@(doc_on_saved={type=T})`, [Plugins](Plugins.md) "Asset types"): the Shader Graph reimports and drops its cached shader, the Render Pipeline reimports.
- **Quitting** with dirty documents asks first, through one check (`quit_gate`, `editor/quit_prompt.odin`) that File/Quit, the window's close button and Relaunch all pass. During a Relaunch, `mh` waits while the editor runs and the ready marker exists. Cancel removes the marker, so nothing launches.

A window that edits an asset keeps the asset's guid and edits its shared document (`inspector.asset_doc_get`), allocating with `inspector.doc_alloc()`. It never keeps the document pointer across frames: an undo, a redo or a Discard replaces the instance.

An editor that applies its edits all at once works on a copy instead (`editor/inspector/asset_doc_copies.odin`). The Sprite Editor does this with a texture's slices.

- `h := inspector.asset_doc_copy_open(path, kind, window)` loads a copy of what the editor edits from disk: the asset's file (`.File`) or its import settings, the .meta (`.Import_Settings`). `view` is the key of the window that holds it. The texture or model itself is never touched.
- `inspector.asset_doc_copy(h)` gives the copy each frame. Undo replaces its value, so the editor keeps the handle and fetches the value through it.
- Edits recorded on the copy become steps on the one undo queue, with no code in the editor. Each step names the copy by its handle, so Ctrl+Z changes only the copy.
- `asset_doc_copy_apply(h)` writes the copy to the file, and the asset's shared document follows. `asset_doc_copy_revert(h)` goes back to the file as one undo step. `asset_doc_copy_discard(h)` drops the unapplied edits and their steps. `asset_doc_copy_close(h)` frees the copy and its steps.
- Until Apply nothing else sees the copy: the Project Inspector shows the file as it is.
- The copy is a document of the window that holds it. Its tab carries the star, the tab menu's Save applies it and Discard drops its edits, File/Save and the quit prompt cover it, and closing the window with unapplied edits asks Apply, Discard or Cancel (`editor/window_close_prompt.odin`).

## Scene window overlays

`@(scene_overlay={id="Tools", order=N})` on a `proc(vertical: bool)` adds an item to a Scene window overlay (`editor/dock.odin`). Items sharing an id sit in one overlay and sort by order. The proc draws imgui widgets and calls `SameLine` between its own widgets when `vertical` is false.

An overlay sits in one of three kinds of place, and the user drags it between them by its grip:

- **A toolbar strip** along the left, right, top or bottom edge. A strip reserves its own space, so the window image shrinks beside it instead of being covered. A strip is only as thick as the items it holds: an overlay in a strip drops its own panel and its grip shrinks to the item height, so the strip hugs the buttons. An empty strip has zero thickness and draws nothing. The top and bottom strips take the corners and span the full width, and the side strips run between them.
- **A floating corner or side** inside the image, drawn over the render.
- **Free floating** anywhere inside the image.

While an overlay drags, every zone highlights and the one under the cursor takes an accent. The outermost band on each edge is the strip, and the floating zones sit just inside it. The top and bottom bands are taller and span the full width, taking the corners, so the side bands run only between them, the same split the drawn strips use. Placement persists per overlay in `UserSettings/editor_settings.json`.

An overlay whose items draw nothing shows no background, grip or hover, and costs its strip no space. A conditional overlay therefore vanishes with its content and returns the moment an item draws again.

A window opts in by taking the strip space before it sizes its image: `overlays_measure_bars`, then `overlay_bar_insets` for the four thicknesses, then `overlays_draw` with both the image rect and the full content rect.

## Editor toolbar

`@(toolbar={zone, order})` on a proc adds a widget to the toolbar above the dock space, in its `"left"`, `"center"` or `"right"` zone. Items sort by order inside a zone. Zones are measured by drawing their items off-screen once per frame, so an item declares no width but keeps it fixed across states. The simulate controls, the run buttons and Relaunch are registered the same way (`editor/window_toolbar.odin`).

## Game window toolbar

The Game window draws its own toolbar above its image (`editor/window_game.odin`):

- **Size**: Free Aspect fills the window, an aspect letterboxes to that ratio, and a fixed resolution renders exactly those pixels, scaled down when it does not fit. The list is built in.
- **Flip**: swaps the selected size's width and height, for portrait targets. Disabled on Free Aspect, which has no ratio to swap.
- **Scale**: zooms the rendered rect. 1x is the size's actual pixels and the maximum is 5x. The minimum is 1x, or the zoom that fits the size in the window when its pixels are larger, so the game is never cropped. Parking the slider at that floor means "match the window": the zoom follows the floor as the window resizes. A 1x button returns to actual pixels, and zoom is disabled on Free Aspect, which already fills the window.

The rendered rect is centered in the area under the toolbar. When the zoom makes it larger than the area, the area scrolls: a scrollbar appears on each axis that overflows, the rect stays centered on an axis that fits, and the mouse wheel stays the game's input, so the bars are dragged. The input viewport follows the rect as it scrolls, so game mouse coordinates stay correct at any size, scale or scroll. Size, flip and scale persist in `UserSettings/editor_settings.json`.
