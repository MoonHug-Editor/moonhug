---
title: "Groups"
description: "Named groups of objects: a Groups component holds membership bits, the lifecycle hooks keep alive and active lists per group, the names live in a Group Names asset"
order: 65
tags: ["components", "engine", "editor"]
path: engine/data
---

A group is a named set of objects game code asks for as a whole: every enemy, every checkpoint, every door. An object can be in several groups. Groups replace one-tag-per-object schemes: membership is a bit set, and a lookup costs the group's member count, not a scan of the scene.

## The Groups component

`engine.Groups` (Scene ▸ Groups) holds the object's membership in `groups`, one bit per group, drawn with the layer picker of the `"group"` domain. An object without the component is in no group. A disabled component keeps the object alive in its groups but out of the active lists.

## The names

The names live in a Group Names asset (`engine.Group_Names`), a `.asset` with 32 names, drawn as the Render Layers asset is. The Groups project setting (Edit ▸ Project Settings… ▸ Groups, `ProjectSettings/groups.json`) names the asset the project uses. The engine keeps a copy of the active asset's names and registers it as the `"group"` layer domain (`plugins/engine/groups.odin`), so a switch of asset, a change on disk and an edit in the inspector all reach the picker at once, with no rebuild ([Layers](Layers.md) has the mechanism).

Game code names a group once, at startup:

```odin
ENEMY: int
@(phase={key=EngineInit, order=100})
my_init :: proc() { ENEMY = engine.group_index("Enemy") }
```

`group_index` panics on a name the asset lacks, so a typo stops the game at launch.

## The lists

The game lifecycle hooks ([Components](Components.md) "Game lifecycle") keep two lists per group:

- `group_alive(g)`: every awake member, in the order they awoke. `comp_awake` adds, `comp_on_destroy` removes.
- `group_active(g)`: the members whose component is enabled on an active object. `comp_on_enable` adds, `comp_on_disable` removes.

Both are empty outside the running game: in edit mode the editor scans the Groups pool instead. The slices are the index's own, so a loop that destroys or regroups members copies the slice first, or queues the destroys with `transform_destroy_later`.

`in_group(tH, g)` reads the bit in every mode. `groups_set(c, mask)` changes membership at runtime and moves the object between lists. A raw write of `groups` while the game runs leaves the lists stale.
