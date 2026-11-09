---
title: "Shader Graph"
description: "Edits a shader graph: properties, the selected node's inputs, the node canvas and the generated GLSL, one undo step per edit"
weight: 10
tags: ["shadergraph", "editor", "windows"]
---

Edits a [shader graph](../assets/ShaderGraph.md). Double-click a `.shadergraph` in the Project window, press Enter on it, or press Open Shader Graph in its inspector. Each graph opens its own window, so graphs are edited side by side.

## Layout

- **Toolbar.** The asset's path, with ` *` while it has unsaved edits. A refused link shows a notice here for a few seconds.
- **Blackboard**, left. One row per property: its name, kind and default, a drag per component or a colour picker, nothing for a texture. A rename lands when the name field is left, and every node reading the property follows it. Add lists the kinds, and the x button removes a property with the nodes that read it.
- **Node**, left, under the blackboard. The selected node's unlinked inputs as drags by port type, a colour picker on the Color node. A linked input shows as linked.
- **Canvas**, middle, the editor's shared node canvas. A node's title is its kind, its property's name for a Property node, `Sample <name>` for a Sample Texture node. Inputs show their port and, while unlinked, their literal. Outputs sit on the right edge. Ports and links are coloured by type, and a node the generator reports an error for draws red.
- **GLSL**, right. The generated shader, or its errors, rebuilt after every edit.

## Editing

- Drag a node to move it. Drag from an output port to another node's input port to link them, replacing the input's old link. A link that would close a cycle is refused. Click a link to select it.
- Right-click empty canvas for the add menu: the palette by category, without Surface while the graph has one, then one entry per property, `Property: <name>`, or `Sample Texture: <name>` and `Normal Map: <name>` for a texture. The node lands where the click was.
- Delete or Backspace removes the selected link, else the selected node. The Surface node is never removed.

## Saving and undo

- The window edits the graph's shared asset document, which File/Save, the tab menu and undo reach ([Windows](/docs/core/Windows.md)). Closing the window keeps unsaved edits in the document, so opening the graph again shows them.
- Every edit is one undo step. Once no widget is active, the window compares the graph with its last recorded copy, and a difference records one step, so a drag records once on release.

## Preferences

Whether the left and right panes show, and their widths, are saved per developer in `UserSettings/shader_graph.json`.
