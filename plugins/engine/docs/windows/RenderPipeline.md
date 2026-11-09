---
title: "Render Pipeline"
description: "Shows a render pipeline's slot as a matrix of passes and the resources they read and write, with live thumbnails, and edits it"
weight: 30
tags: ["engine", "editor", "windows", "rendering"]
path: engine/windows
---

Shows a render pipeline one slot at a time, as a matrix of its passes and the resources they read and write, and edits it. Open it from a pipeline's Open Render Pipeline button, or from Window, Rendering, Render Pipeline for the active pipeline. Each pipeline opens its own window.

## The matrix

- **Columns** are the slot's passes in run order, the frame lane's left of a divider. Each lane ends with a `+` column that adds a pass from the palette of installed steps.
- **Rows** are the resources: `scene`, the view's objects, then every target in the order it first appears, with its format and size.
- **Cells** mark what a pass does to a resource: writes it, a square, reads it, a circle with a dot when it reads it as `final`, or reads and writes it in place. A red ring is a read with no writer before it. A bar spans each resource's lifetime.
- Selecting a pass tints the rows it reads, writes and changes in three colours. Selecting a row outlines it, and its tooltip names its writers and readers.

## Editing

- Drag a header onto another to reorder a pass, or to move it between the frame lane and the slot. Right-click a header to insert before or after it, mute it, open its code or remove it.
- The tabs add, rename and remove slots.
- Edits render as they are made. Each is one undo step, and a save reimports the asset. The window edits the pipeline's shared asset document, the one the Project Inspector shows.

## The side pane

Three sections, each shown or hidden by its toolbar button:

- **Selected Pass**: its summary, its inputs and outputs as thumbnails from the running frame, Show in Scene window per output, its settings, mute, open code, remove, its port bindings, and what it drew. A click on a drawn object selects it, on an asset pings it.
- **Resource List** and **Pass List**: every row and column with its details, searchable. Filter hides scratch resources, the `scene` row and muted passes.

The pane's width and the split between its sections are saved per developer in `UserSettings/render_pipeline.json`.

## Inspecting a frame

While the window draws, the engine captures the slot it shows and copies each step's targets into thumbnails, so an in-place target like `hdr` has one image per pass. A closed window costs nothing ([Render pipeline](../RenderPipeline.md), "Inspecting a frame").
