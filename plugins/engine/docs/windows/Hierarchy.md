---
title: "Hierarchy"
description: "The loaded scenes and their objects as trees: select, filter, rename, reparent by drag and drop, create from the context menu, and step into nested scenes"
weight: 10
tags: ["engine", "editor", "windows"]
path: engine/windows
---

The loaded scenes and their objects, each scene a header row with its objects as a tree under it. Several Hierarchy windows can be open, each with its own folds and filter.

## Rows

A row, left to right:

- **The gutter:** the pick lock. It shows on the row under the pointer and on a locked object, dimmed on an object locked by one above it ([Scenes](../Scenes.md)). The lock on a scene's header is always shown and locks every object of the scene.
- **The fold arrow** of an object with children. A click anywhere left of the glyph folds the row and does not select it. Alt-click folds or unfolds everything under it.
- **The glyph:** a cube for an object, stacks for a nested scene's instance, the variant glyph for a variant.
- **The name.** A nested scene's instance and its content are blue. An object that is off, or under one that is off, is dimmed.
- **`>`** at the right end of a nested scene's instance opens its source scene in place of the current one.

Marks on a nested scene's instance:

- A bar at the row's left edge: the instance has values, components or objects of its own in this scene.
- A `+` on the glyph: the object was added to the instance in this scene.

A scene's header shows the scene's name, dimmed for a scene that is not the active one, with `*` while it has unsaved changes. Its arrow folds the scene's objects. A click on the name shows the scene's file in the Project window. The button at its right end, or a right click, opens its menu. Inside an entered nested scene, `<` left of that button returns to the scene it came from.

The selected rows are highlighted across the window, in grey while the window is not the focused one.

A scene's rows open as they were left: after another scene, and after a restart. The open rows are kept per scene, per developer, in `UserSettings/hierarchy_folds.json`, until the scene leaves the project. A scene that has never been saved keeps none. A window opened later shows a scene's rows as last left in any window.

## Selecting

- A click selects one object, Cmd-click adds or removes one, and Shift-click selects the range of visible rows between ([Multiselection](/docs/core/Multiselection.md)).
- The keys move the selection: Up and Down, with Shift to extend it.

## Editing

- Drag objects onto another to reparent them, or between rows to reorder them. A selected row drags the whole selection.
- A line marks a place between rows. It starts at the depth the object will have. A frame marks a row the object goes under. Below an open row the line is one step in: the object becomes that row's first child.
- A folded row opens when a drag rests on it for a moment. Near the top and bottom edges the list scrolls under the drag.
- A drop on a scene's header or on its root object puts the object under the root, at the end.
- Drag a file or sub-asset from the Project window onto a row to make an object of it under that row, between rows to put it there, or onto empty space to make it under the scene's root: a scene becomes a nested instance, a model its node hierarchy, a sprite a SpriteRenderer ([Asset drop](../attributes/AssetDrop.md)). A scene dropped on the window's background opens beside the loaded scenes.
- Drag objects onto a Project folder to make prefabs of them there ([Scene](../assets/Scene.md#making-a-prefab-of-objects)).
- While a drag hovers, its tooltip says what a drop there does ([Drag and drop](/docs/core/DragAndDrop.md)).
- The `+` button and a right click on empty space open the GameObject menu's create items. A new object becomes the selection in the same undo step.
- GameObject, Create Prefab writes each selected object to a new scene file and puts an instance of it in its place ([Scene](../assets/Scene.md#making-a-prefab-of-objects)).
- A scene's header menu has Save, Save As, Discard, which reloads the scene from its file, and Unload.
- The Filter field shows only the objects that match every word in it, as a flat list. The selected object's path shows under the list. A word matches inside an object's name. A word that starts with `c:` matches part of a component type's name: `c:sprite` shows the objects with a Sprite or a SpriteRenderer. A `$` at the end marks the end of the name: `c:sprite$` shows the objects with a Sprite only. `c:mesh enemy` shows the objects named like "enemy" that have a mesh component. The Project window's search takes the same words ([Windows](../../../../docs/core/Windows.md#search-fields)).

## Keys

| Key | Command |
|---|---|
| Down, Up | Hierarchy/Select Down, Hierarchy/Select Up |
| Shift+Down, Shift+Up | Extend the selection down or up |
| Right, Left | Hierarchy/Expand, Hierarchy/Collapse: open or close the children, or step into or out of them |
| Alt+Right, Alt+Left | Open or close every descendant |
| F | Edit/Frame Selected |
| Enter, F2 | Hierarchy/Rename |
| Escape | Hierarchy/Clear Filter |
