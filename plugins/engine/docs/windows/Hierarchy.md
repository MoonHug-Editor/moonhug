---
title: "Hierarchy"
description: "The loaded scenes and their objects as trees: select, filter, rename, reparent by drag and drop, create from the context menu, and step into nested scenes"
weight: 10
tags: ["engine", "editor", "windows"]
path: engine/windows
---

The loaded scenes and their objects, each scene a section with its objects as a tree. Several Hierarchy windows can be open, each with its own folds and filter.

## Selecting

- A click selects one object, Cmd-click adds or removes one, and Shift-click selects the range of visible rows between ([Multiselection](/docs/core/Multiselection.md)).
- The keys move the selection: Up and Down, with Shift to extend it.

## Editing

- Drag objects onto another to reparent them, or between rows to reorder them.
- Right-click empty space for the GameObject menu's create items. A new object becomes the selection in the same undo step.
- A scene's header menu has Discard, which reloads the scene from its file, Unload and Save Scene As.
- The Filter field shows only the objects that match every word in it. A word matches inside an object's name. A word that starts with `c:` matches part of a component type's name: `c:sprite` shows the objects with a Sprite or a SpriteRenderer. A `$` at the end marks the end of the name: `c:sprite$` shows the objects with a Sprite only. `c:mesh enemy` shows the objects named like "enemy" that have a mesh component. The Project window's search takes the same words ([Windows](../../../../docs/core/Windows.md#search-fields)).
- An object that is a nested scene's instance has a `>` button that opens its source scene in place of the current one. `<` returns to the scene it came from.

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
