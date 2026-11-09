---
title: "Groups"
description: "Puts its object in any of 32 named groups that game code asks for by name"
weight: 90
tags: ["engine", "components"]
path: engine/components
---

Puts its object in any of 32 named groups, so game code finds every member of one: every enemy, every pickup.

## Properties

| Field | Default | What it does |
|---|---|---|
| `groups` | none | The groups the object is in, one bit each. The names come from the Group Names asset the Groups project setting picks. |

## Behavior

- An object joins its groups' alive lists when it wakes and leaves them when destroyed, and their active lists while it is enabled. `group_alive` and `group_active` read the lists, always up to date ([Groups](../Groups.md)).
