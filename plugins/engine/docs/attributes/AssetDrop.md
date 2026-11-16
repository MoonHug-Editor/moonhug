---
title: "Asset drop"
description: "@(asset_on_drop): what a file or sub-asset dragged from the Project window into the Scene window or the Hierarchy becomes"
weight: 60
tags: ["engine", "attributes", "editor"]
path: engine/attributes
---

A file or sub-asset dragged from the Project window into the Scene window or the Hierarchy becomes an object. What it becomes is up to the package that knows the asset type, with an `@(asset_on_drop)` proc.

## Where the object goes

- **Scene window:** under the active scene's root, where the pointer meets the nearest object. Objects are met the way a click picks them, so a mesh is met at its bounds. Over empty space it goes where the pointer meets the grid: the XY plane in the 2D view, otherwise the first plane the grid shows, XZ when it shows none. A pointer that meets no plane in front of the camera puts it at the camera's pivot distance.
- **Hierarchy:** under the row it is dropped on, or under the scene's root on empty space, at its parent's origin.
- The drop is one undo step and selects the new object.
- The Scene window takes only an asset some package makes an object of.

## What the engine and its plugins make

| Asset | Kind | Becomes |
|---|---|---|
| Scene (a prefab) | `scene` | a nested instance of it |
| Model | `glb`, `gltf` | its node hierarchy, each mesh node with its part, a skinned one with a SkinnedMeshRenderer. The material slots stay empty, so the default material draws. Assets, Extract Assets gives a scene with the model's own materials. |
| Model part | `mesh` | one object with a MeshFilter naming the part and a MeshRenderer |
| Texture, with the sprites plugin | `png`, `jpg`, `jpeg`, `bmp` | an object with a SpriteRenderer drawing the whole texture, or its first slice when it is sliced |
| Sprite, with the sprites plugin | `sprite` | an object with a SpriteRenderer drawing the slice, named after it |

## @(asset_on_drop)

```odin
@(asset_on_drop={kind="sprite"})
asset_on_drop_sprite :: proc(ref: engine.PPtr, parent: engine.Transform_Handle) -> engine.Transform_Handle {
    tH := engine.transform_new("Sprite", parent)
    // add components, set their fields
    return tH
}
```

- `kind` is what the proc takes: a file extension without the dot, or the kind of a sub-asset as the Project window search's `t:` word knows it. Several kinds are separated by spaces. One proc per kind: a second stops the build.
- The proc builds the object under `parent` and returns its root, or `{}` for an asset it makes nothing of. It leaves the position, the undo step and the selection to the drop.
- The proc is named `asset_on_drop_<name>` and lives in an editor package, never the editor root.
- `scene_tools.asset_drop(ref, parent, at)` drops from code, as both windows do.

## Reference

- [@(asset_on_drop)](/docs/reference/attributes/engine/asset_on_drop.md)
- Code: `plugins/engine/editor/scene_tools/asset_drop.odin`, the generator `plugins/engine/gen/asset_drop_gen.odin`.
