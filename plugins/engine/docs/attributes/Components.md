---
title: "Components"
description: "@(component): a struct that is pooled in every world, attached to objects, saved in scenes and listed in Add Component"
weight: 10
tags: ["engine", "attributes", "components"]
path: engine/attributes
---

`@(component)` makes a struct a component. It is pooled in every world, attached to objects, saved in scenes, and listed in Add Component and the Component menu.

## Example

```odin
@(component={menu="Demo/Lifetime"})
@(typ_guid={guid = "c3a1e4f2-7b8d-4a2e-9c5f-1d6e3b0f7a8c"})
Lifetime :: struct {
    using base: engine.CompData `inspect:"-"`,
    duration:   f32,
    time_spent: f32 `inspect:"-"`,
}

type_reset_Lifetime :: proc(comp: ^Lifetime) {
    comp.duration = 1
}
```

## Rules

- The struct embeds `engine.CompData` as `using base`. It holds the owner object, the local id and the enabled flag.
- `@(typ_guid)` is the type's identity in scene files. It never changes, so a rename keeps every scene loading.
- `type_reset_T` sets the defaults of a new component and of the inspector's Reset. `type_on_validate_T` clamps values after every edit and load. `type_cleanup_T` frees what the instance owns.
- Fields save by name. A field missing from a file keeps its reset default ([Component data](../Components.md), "Missing fields and reset defaults").

## Fields

| Field | What it does |
|---|---|
| `menu` | The path in the Component menu and in Add Component, such as `"Rendering/Camera"`. A plugin's components go under the plugin's name. |
| `ref_tags` | Capability tags a reference field with `has:"@Tag"` matches, such as `"Output"` for what a timeline track can drive. |
| `max` | The pool's size in every world. Going past it stops the program with an error that names the type. |

## Reference

- [@(component)](/docs/reference/attributes/engine/component.md)
- [Component data](../Components.md): the model, the access rules and the two data regimes.
