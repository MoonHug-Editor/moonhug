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

## The file

JSON: the scene's objects by local id, each with its transform and components. Components carry stable local ids, so references between objects survive saving and reloading ([Scenes](../Scenes.md)).

A scene file can also hold assets of its own, such as materials its objects use, and a field can hold an asset written inside it: [Sub-assets and Embedded Assets](../../../../docs/core/SubAssets.md).
