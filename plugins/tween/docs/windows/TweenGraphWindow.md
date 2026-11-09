---
title: "Tween Graph"
description: "Shows a tween tree on a canvas and edits it node by node: select a node to edit its fields, change types, add and delete nodes"
weight: 10
tags: ["tween", "editor", "windows"]
---

Shows a tween tree on a canvas and edits it node by node. Open it with an `Authored` field's Graph button, or from Window, Animation, Tween Graph.

## Editing

- Selecting a node shows it in the window's panel, drawn by the regular inspector. A released edit writes back into the tree as one undo step of the whole component.
- A node's type button changes its type: the fields reset to the new type's defaults, and the children stay when the new type is a composite.
- Add Child adds a node under a composite, and Delete Node removes any node but the root. Each is one undo step.
- Every picker lists the registered node types, so an installed plugin's nodes appear with nothing to set up.
- The selection is a path of child positions, so it survives undo.
