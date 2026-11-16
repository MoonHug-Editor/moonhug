---
title: "Scene"
description: "A .scene file: objects and their components, used as a level, as a prefab instanced into other scenes, or as a variant of another scene"
weight: 80
tags: ["engine", "assets", "scenes"]
path: engine/assets
---

A `.scene` file: a tree of objects and their components. The same file is a level, a prefab instanced into other scenes, or a variant of another scene. Assets, Create, Scene makes one, and Scene Variant makes a variant of the selected scene.

## Uses

- **A level.** Double-click it to open it. Several scenes can be loaded at once, each a section in the [Hierarchy](../windows/Hierarchy.md).
- **A prefab.** Drag it into another scene to place an instance. Edits to an instance are overrides, kept in the scene that holds it, and the source's own edits reach every instance ([Nested prefabs](../NestedPrefabs.md)).
- **A variant.** A scene whose root is an instance of another scene, with its own overrides on top ([Prefabs specification](../PrefabsSpec.md)).

## Making a prefab of objects

GameObject, Create Prefab, in the main menu or an object's context menu, turns each selected object into a prefab:

- The object and everything under it are written to a new scene file in the Project window's open folder, named after the object. The file's root sits at its own origin.
- The object becomes an instance of that file, in its place: same parent, same position among its siblings, same position.
- References between the objects stay inside the prefab. References from the rest of the scene to them now name the instance's objects. References from them to the rest of the scene cannot live in an asset: the file has them empty, and the instance keeps them as overrides.
- Prefab instances inside the object stay prefab instances in the new file.
- One undo step puts the objects back. The file stays.
- Not for a scene root, a prefab instance or what is inside one, nor while the game runs. The menu item says why when it is greyed out.

## The file

JSON: the scene's objects by local id, each with its transform and components. Components carry stable local ids, so references between objects survive saving and reloading ([Scenes](../Scenes.md)).

A scene file can also hold assets of its own, such as materials its objects use, and a field can hold an asset written inside it: [Sub-assets and Embedded Assets](../../../../docs/core/SubAssets.md).
