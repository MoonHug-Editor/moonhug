---
title: "Drag and drop"
description: "What a drag carries between the editor's windows, where it can land, and the rules that say what a drop does there"
weight: 45
tags: ["editor", "drag and drop"]
path: editor/editing
---

Every drag of content between the editor's windows goes through one package, `moonhug/editor/drag`. A drag carries items, lands on a place, and a rule says what the drop does there. While the drag hovers, the same rule says what a release would do, and the drag's tooltip shows it: "Make prefab Tank.scene", "Move Turret under Tank".

## What a drag carries

A list of items, each one of:

- **an asset**: a file, or a sub-asset of a file, as a `PPtr` (local id 0 for the file);
- **a scene object**: a `Transform_Handle`;
- **a folder of the project**: a `Folder` with its path, since a folder has no asset id.

The Project window's rows drag assets and folders, and the Hierarchy's rows drag objects. A row that is part of the selection drags the whole selection: the selected assets and folders, or the top-level selected objects.

## Where it lands

| Place | What the rule gets | Where |
|---|---|---|
| `scene` | `Scene_Place`: the view, the pixel, and the grid point under it | the Scene window's image |
| `hierarchy` | `Hierarchy_Place`: a parent and a child index, -1 for the end | before or after a row (its parent, at its place), after an open row (its first child), on a row (its last child), on a scene's header or below the rows (the scene's root), the window's background (no parent) |
| `project` | `Project_Place`: a folder's path | a folder in the tree, the list or the path bar, a file (its folder), the empty part of the list (the open folder) |

## What a drop does

A rule is a proc with `@(drop={what, on})`, named `drop_<name>`. `what` is what every item is: `object`, `asset`, or `asset:<kind>`, the kind of a file (its extension) or of a sub-asset, as the Project search's `t:` knows it. A rule added by a call to `drag.drop_rule_add` can also name `file`: every item is a file of the project or a folder of it. `on` is the place. The rules of one place are asked in order, a kind before plain `asset`, and the first that takes the items does the drop.

The editor's rules:

| What | On | Does | Rule |
|---|---|---|---|
| assets | scene | an object of each, where the pointer meets an object, or on the grid ([Asset drop](/plugins/engine/docs/attributes/AssetDrop.md)) | `drop_assets_in_scene` |
| objects | hierarchy | moves them under the place's parent, at its index | `drop_objects_in_hierarchy` |
| scenes | hierarchy, background | opens them beside the loaded scenes | `drop_scenes_in_hierarchy` |
| assets | hierarchy | an object of each under the place's parent ([Asset drop](/plugins/engine/docs/attributes/AssetDrop.md)) | `drop_assets_in_hierarchy` |
| objects | project | a prefab of each in the folder, the objects becoming its instances ([Scene](/plugins/engine/docs/assets/Scene.md#making-a-prefab-of-objects)) | `drop_objects_in_project` |
| files and folders | project | moves them into the folder, each file with its `.meta`, so it keeps its id ([Project](/docs/core/ProjectWindow.md)) | `_drop_files_in_folder` |

The reference page of `@(drop)` lists every rule the installed plugins add.

A rule is asked every frame the drag hovers, with `perform` false: it returns whether it takes the items and sets `hint`, and changes nothing. On release it is asked once more with `perform` true and does the drop, as one undo step.

```odin
@(drop={what = "object", on = "project"})
drop_objects_in_project :: proc(d: ^drag.Drop) -> bool {
    folder := d.place.(drag.Project_Place).folder
    if !d.perform {
        d.hint = "Make prefab"
        return true
    }
    // make the prefabs
    return true
}
```

## Reference fields

An inspector reference field takes a drag of one item its type admits, with no rule: a file, a sub-asset or an object, as the field's drawer asks ([Object picker](ObjectPicker.md)).

## Not drag and drop of content

Window tabs, and blocks reordered inside one window (the Render Pipeline window's columns), drag on imgui payloads of their own: they move layout, they carry no content.

## Tests

`drag.run(items, place, perform)` asks the rules as a drop would, so a test drops with no mouse. Scenarios drive real drags with the bridge's `input`, and `item_rect` with the window `tooltip` reads what the drag says while it hovers ([MCP bridge](McpBridge.md)).
