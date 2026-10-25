---
title: "Inspector"
description: "How the inspector addresses, draws and edits fields, and how a field picks a reference"
weight: 20
path: editor/inspector/_index.md
---

The inspector draws any struct by reflection and records every edit on the undo stack. These pages cover the two pieces a plugin meets when it adds its own fields and drawers.

- [Inspector Property](../InspectorProperty.md): a field addressed by its owner and a dotted path, carrying its value, undo owner and prefab override target. Every drawer receives one, so start here.
- [Object Picker](../ObjectPicker.md): the popup a reference field opens to pick a scene object or an asset, with its filters and indexes.

Drawers and decorators are declared with attributes and field tags. The [Attributes](../../reference/attributes/_index.md) and [Field tags](../../reference/field_tags/_index.md) references list every one with its uses.
