---
title: "Groups"
description: "Puts its object in any of 32 named groups, which game code reads as lists of members"
weight: 90
tags: ["engine", "components"]
path: engine/components
---

A group is a named set of objects that game code asks for as a whole: every enemy, every checkpoint, every door. The Groups component puts its object in any of 32 groups, and an object without one is in no group. Membership is one bit per group, and reading a group costs its member count, not a scan of the scene.

## Example

```
Goblin     Groups groups Enemy
Door       Groups groups Interactable
Chest      Groups groups Interactable, Loot
```

Game code asks for every enemy or every interactable object by group, with no scan of the scene. The chest is in two groups.

## Properties

| Field | Default | What it does |
|---|---|---|
| `groups` | none | The groups the object is in, one bit each, picked by name. |

## Group names

The names come from the [Group Names](../assets/GroupNames.md) asset that the Groups project setting picks. Game code turns a name into a group index once, at startup:

```odin
ENEMY: int

@(phase={key=EngineInit, order=100})
my_init :: proc() { ENEMY = engine.group_index("Enemy") }
```

`group_index` panics on a name the asset lacks, so a typo stops the game at launch.

## Reading a group

- `group_alive(g)` lists every awake member, in the order they awoke. `comp_awake` adds an object and `comp_on_destroy` removes it.
- `group_active(g)` lists the members whose Groups component is enabled on an active object. `comp_on_enable` adds an object and `comp_on_disable` removes it.
- `in_group(tH, g)` reads one object's bit.

Rules:

- The lists are kept only while the game runs, and they are empty in edit mode. `in_group` works in every mode.
- A disabled component keeps its object in the alive lists and out of the active lists.
- The slices belong to the index. A loop that destroys or regroups members copies the slice first, or queues the destroys with `transform_destroy_later`.

## Changing membership at runtime

`groups_set(c, mask)` changes the bits and moves the object between lists. A direct write of `groups` while the game runs leaves the lists stale until `groups_resync(c)`. Inspector edits reach the lists through the undo stack.
