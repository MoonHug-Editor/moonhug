---
title: "Playable Graph window"
description: "A read-only view of the playable graph that poses the selected object, with live weights while it plays"
weight: 20
tags: ["animation", "editor", "windows"]
---

Shows the [playable graph](../concepts/PlayableGraph.md) that poses the selected object: its clip nodes, mixers and output, with the weights that connect them. It is read-only.

## What it shows

- The graph of the selected object or one of its ancestors, so selecting a bone keeps the window on the animated root.
- Several things own graphs, and the window shows the most live one. Searching up from the selection it compares every object's best source and takes the lowest order, not the nearest object:

| Order | Source | Weights |
|---|---|---|
| 10 | a TimelineAnimator's runtime graph | live |
| 20 | an Animation component's runtime graph | live |
| 30 | a timeline director's animation tracks, or the animator that adopted them | live |
| 40 | the Animation window's preview | live |
| 50 | the shape the Animation component builds when it plays, rebuilt from its states | structural only |

- An object can carry an Animation with no clips while a TimelineAnimator further up poses it. Comparing orders across the chain shows the animator's graph rather than the empty one.
- The source's name shows above the canvas. Without a source the window says to select an object that owns a playable graph, and an empty graph says there is nothing to play.

## Reading the graph

- Clip nodes sit on the left and the output on the right. Nodes are laid out by their depth from the output.
- Each kind of node has its own colour: a pose source, a blend, the layer stack and a script. The output has a colour of its own, since it is where the pose leaves the graph.
- With a live source, an edge's opacity and label follow its input weight.

## Using it

- Pan and zoom the canvas. Nodes can be dragged, and keep their place until the graph's structure changes, when the layout is computed again.
- Ports are drawn but take no input: the window edits nothing.
- The canvas is the editor's shared node canvas (`moonhug/editor/node_canvas`): a pan and zoom grid, node chrome with ports, edges, dragging and selection. It is presentation and interaction only. Each window that draws on it supplies its own node types, port rules and what an edit does, so a shader graph and a playable graph share the canvas and nothing else.

## See also

- [Playable graph](../concepts/PlayableGraph.md), "Who owns a graph", for how owners register their graphs.
- [Animation](../components/Animation.md), "The graph it builds".
