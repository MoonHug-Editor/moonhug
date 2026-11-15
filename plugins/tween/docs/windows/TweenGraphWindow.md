---
title: "Tween Graph"
description: "Shows a tween tree on the shared node canvas and edits it node by node: select a node to edit its fields, change types, add and delete nodes, and preview the tree in edit mode"
weight: 10
tags: ["tween", "editor", "windows"]
---

Shows a tween tree of the selected object on a canvas and edits it node by node. Open it from Window, Animation, Tween Graph, or with an `Authored` field's Graph button.

## What it shows

- The selected object's trees: every `Authored` field of every component on it, in the components' order and then in field order. The toolbar lists them by component and field path, such as `TweenPlayer.animations[1]: Sequence`. An object with two components of one type numbers them: `TweenPlayer #2.animations[0]`.
- A tree in an array is named by its index in the array, so giving a type to an empty slot before it does not change which tree shows.
- The window shows the tree last picked in its toolbar or with a Graph button, whenever its object has it: the same component type, the same one of that type, the same field. Otherwise it shows the object's first tree and keeps the pick for the next object that has it. An object with none says so.
- The pick is saved with the window, so it comes back after a restart.
- The padlock in the tab bar locks the window to the object selected now, as the Inspector's does. A locked window keeps its object while the selection moves on, and keeps the lock through a close and Reopen Closed, a restart, and a workspace frame. When its object is not here, its scene closed or the object deleted, the window says so and shows it again when it is back.
- The tab menu's Add Tab opens another copy. Each copy has its own lock, picked tree, selected node and view.
- An `Authored` field's Graph button shows its tree in every copy that shows its object, and brings the first of them to the front.

## Layout

- **Toolbar.** The object and the tree, with every tree on the object to pick from, Preview, Frame All, and on the right the Node toggle and the mini-map toggle.
- **Canvas**, the editor's shared node canvas, the one Shader Graph and Playable Graph draw on. The tree reads left to right: a node's children sit in the column to its right, joined from its right edge to their left edges. A node shows its type, then one row for each of its own subject (`on Door`, or `on Missing` when the object is gone), its delay, await and skip. A skipped node is drawn faded.
- **Node**, right. The selected node's fields. Drag the gap between it and the canvas to resize it. The Node toggle hides and shows it.
- **Mini-map**, over the canvas, top right. The whole tree and the visible area. Click or drag in it to go there. Hold Ctrl or Cmd and drag to move it, drag a corner to resize it. The map toggle hides and shows it.

## Moving around

- Drag empty canvas or a node with the left button, or drag anywhere with the middle button, to pan. A middle drag goes on when the mouse leaves the canvas.
- The wheel zooms around the mouse.
- Nodes are laid out from the tree, so dragging one pans the canvas rather than moving it.

Whether the node panel shows, its width, and the mini-map's place are saved per developer in `UserSettings/tween_graph.json`, and every copy shares them.

## Editing

- Selecting a node shows it in the window's panel, drawn by the regular inspector. A released edit writes back into the tree as one undo step of the whole component.
- A node's type button changes its type: the fields reset to the new type's defaults, and the children stay when the new type is a composite.
- Add Child adds a node under a composite, and Delete Node removes any node but the root. Each is one undo step.
- Every picker lists the registered node types, so an installed plugin's nodes appear with nothing to set up.
- The selection is a path of child positions, so it survives undo.
- A node's `subject` is a reference field like any other: pick an object with its search button, or drag one in from the Hierarchy. It shows the object's name.

## Preview

The Preview button plays the shown tree on its object in edit mode, with no Play.

- The tree runs on the object the component is on. A node with its own `subject` animates that object, as in a game.
- The pose shows in the Scene and Game views only. Everything else sees the authored values: a save, undo, the inspector and the gizmos. A preview never ends up in a saved scene, the same way the Animation and Sequencer previews work.
- An edit made during a preview is kept, and the preview goes on from it.
- One preview plays at a time. Starting one ends another, and every copy showing the playing tree shows Stop.
- When the tree is done it shows its end pose for a moment and ends. Stop ends it at once. Closing the copy that shows it, picking another tree in it and entering Play end it too.
- It keeps playing when the Tween Graph is a hidden tab.
- A wait in the tree holds the preview, since nothing in edit mode ends it. Stop ends it.
- An event node calls nothing in a preview: the code that listens is not running.
- The button is off in Play, where the game starts the tree.
- The editor draws at its full rate while a preview plays, not at its idle rate.
