---
title: "Lifecycle"
description: "@(comp_awake), @(comp_on_enable), @(comp_on_disable) and @(comp_on_destroy): game logic when a component enters, toggles and leaves the running game"
weight: 20
tags: ["engine", "attributes", "components"]
path: engine/attributes
---

Four attributes run game logic on one component instance as it enters, toggles and leaves the running game. They never run in edit mode or on preview content.

| Attribute | Runs |
|---|---|
| `@(comp_awake)` | Once, when the instance enters the running game: at play start, or right after its creation while the game runs. |
| `@(comp_on_enable)` | When the instance becomes enabled: right after its awake when it is, then on every change to its enabled flag or its object's active state. |
| `@(comp_on_disable)` | When the instance stops being enabled, and before `comp_on_destroy` when it was. |
| `@(comp_on_destroy)` | When the instance leaves the running game: its object destroyed, the component removed, its scene unloaded, play stopped or the player quitting. |

## Example

```odin
@(comp_awake={component=Groups})
comp_awake_Groups :: proc(c: ^Groups) {
    // every component of the creation exists here, with its references bound
}
```

## Rules

- `component = T` names a `@(component)` type of the same package. The proc is `proc(c: ^T)`, named `comp_<attribute>_T`. The generator enforces the name, so a type has at most one of each.
- Awake runs in two passes over a creation: `comp_awake` on everything, then `comp_on_enable` on everything enabled. The first `comp_on_enable` sees the whole creation awake, so there is no separate start hook.
- `comp_on_destroy` is for game logic and for what `comp_awake_T` created outside the instance. `type_cleanup_T` runs right after it and frees what the instance owns.

## Reference

- [@(comp_awake)](/docs/reference/attributes/engine/comp_awake.md), [@(comp_on_enable)](/docs/reference/attributes/engine/comp_on_enable.md), [@(comp_on_disable)](/docs/reference/attributes/engine/comp_on_disable.md), [@(comp_on_destroy)](/docs/reference/attributes/engine/comp_on_destroy.md)
- [Component data](../Components.md), "Game lifecycle": the order, batching and how enable changes are noticed.
