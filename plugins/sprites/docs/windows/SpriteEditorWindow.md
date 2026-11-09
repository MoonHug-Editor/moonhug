---
title: "Sprite Editor"
description: "Cuts a texture into slices, each with a rect, a pivot and borders, applied to the texture's import settings"
weight: 10
tags: ["sprites", "editor", "windows"]
---

Cuts a texture into slices: named rectangles, each with a pivot and 9-slice borders. Open it from the Sprite Editor button under a texture's import settings in the Project Inspector.

## Layout

- **Toolbar.** Slice, Apply and Revert, the Scale slider, and the Sprites and Properties toggles that show or hide the side panes.
- **Sprites pane.** The list of slices, to select, add and remove.
- **Canvas.** The texture with every slice's rectangle. The wheel zooms, middle drag pans, and scrollbars appear when the zoomed texture is larger than the canvas.
- **Properties pane.** The selected slice's name, rectangle, pivot and border.

## Editing

- Drag on an empty spot to draw a new slice, and drag a slice to move it.
- The selected slice's borders, or the whole texture's in Single mode, show as guide lines on the canvas. Drag a line to move its border, or type the border in the Properties pane: left, top, right and bottom, in pixels from each edge.
- Slice opens the slicing popup: Automatic finds sprites by their transparent surroundings, Grid By Cell Size and Grid By Cell Count cut a grid. The popup also sets the new slices' pivot.
- Delete or Backspace removes the selected slice.

## Applying

- Edits go to a working copy of the texture's import settings. Apply writes the `.meta` and reimports the texture, Revert drops the edits. Each finished edit is one undo step.
- Unapplied edits put a star on the tab. The tab's menu, File/Save and the quit prompt apply or discard them. Closing the window, or opening it on another texture, asks first.
- Several Sprite Editor windows can be open. Each has its own zoom and pan, and all of them edit the same texture.

## Preferences

Which side panes show and their widths are saved per developer in `UserSettings/sprite_editor.json`. A new window starts from them.

## Keys

| Key | Command |
|---|---|
| Delete, Backspace | Sprite Editor/Delete Slice |

## See also

- [Sprites and slices](../concepts/SpritesAndSlices.md)
