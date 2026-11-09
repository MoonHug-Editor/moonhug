---
title: "Group Names"
description: "The names of the 32 groups the Groups component puts objects in"
weight: 70
tags: ["engine", "assets"]
path: engine/assets
---

The names of the 32 groups a [Groups](../components/Groups.md) component puts its object in. Assets, Create, Group Names makes one, and the Groups project setting picks the one the project uses. The setting is saved in `ProjectSettings/groups.json`.

| Field | What it does |
|---|---|
| `names` | The group names. An empty name is an unused group. |

## How names reach the editor

- The engine keeps a copy of the active asset's names and registers it as the `"group"` layer domain.
- Switching the asset, a change on disk and an edit in the inspector all reach the Groups picker at once, with no rebuild. The render layers work the same way ([Layers](../Layers.md)).
- The inspector draws the asset like a Render Layers asset.
