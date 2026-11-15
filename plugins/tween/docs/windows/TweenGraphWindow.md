---
title: "Tween Graph"
description: "Shows a tween tree on a canvas and edits it node by node: select a node to edit its fields, change types, add and delete nodes, and preview the tree in edit mode"
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
- A node's `subject` is a reference field like any other: pick an object with its search button, or drag one in from the Hierarchy. It shows the object's name.

## Preview

The Preview button plays the open tree on its object in edit mode, with no Play.

- The tree runs on the object the component is on. A node with its own `subject` animates that object, as in a game.
- When the tree is done it shows its end pose for a moment, then every value it changed is put back. Stop puts them back at once.
- Closing the window, opening another tree and entering Play end the preview and put the values back too.
- A wait in the tree holds the preview, since nothing in edit mode ends it. Stop ends it.
- An event node calls nothing in a preview: the code that listens is not running.
- The button is off in Play, where the game starts the tree.
- The editor draws at its full rate while a preview plays, not at its idle rate.
