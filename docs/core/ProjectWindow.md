---
title: "Project"
description: "The Project window: the folder tree, the list and the grid of a folder's contents, search, moving files by drag, and what keeps it cheap to draw"
weight: 115
tags: ["editor", "windows", "assets"]
path: editor
---

The project's files. A folder tree on the left, the contents of the folder it shows on the right, and a search box over both. Several Project windows can be open, each on its own folder.

## The tree

- The `assets` folder, then `packages` with a row per installed package. A package's row shows its assets folder under the package's name. A linked folder has a link glyph.
- The tree lists folders only. A click shows the folder in the list and selects it.
- The folder the list shows is always marked, in grey while the keyboard is in the list or the window is not the focused one.
- A click on the arrow, or a double click on the row, folds the folder.
- A right click shows the folder and opens the Assets menu for it.

## The list

- The path bar on top names the folder, each part a link to that folder. With several items selected it shows their count, and during a search the number of hits.
- Folders first, then files. A file with sub-assets has a fold arrow, and its sub-assets are rows under it.
- The slider in the footer picks the form: rows at its low end, a grid of thumbnails above it, larger with the value.
- A name too long for its row or cell is cut in the middle with its extension kept. The whole name shows when the pointer rests on it.
- The footer shows the path of the selected item.
- `*` after a name marks a file with unsaved changes. A file of an unknown type and a cut file are dimmed.

## Selecting

- A click selects one item, Cmd-click adds or removes one, Shift-click selects the range between ([Multiselection](/docs/core/Multiselection.md)).
- A right click selects the item under it, a folder too, unless it is part of the selection already.
- In the grid a drag from empty space draws a band, and the cells it covers are the selection. With Shift or Cmd the band adds to the selection.
- A double click opens a folder or a file. On a sub-asset it opens what its file's provider opens.

## Moving

- Drag files and folders onto a folder to move them there: a folder in the tree, in the list, or in the path bar. A file moves with its `.meta`, so it keeps its id and every reference to it.
- While the drag hovers, its tooltip says what the drop does. A folded folder of the tree opens when the drag rests on it, and a pane scrolls when the drag is near its top or bottom edge.
- When a name is taken in the target folder, the editor asks: Replace moves what is there to the Trash, Keep Both gives the new item another name, Skip leaves both where they are. One answer covers every clash of the drop. A paste asks the same.
- The roots do not move: `assets`, `packages` and a package's assets folder.
- Cut and Paste move files too, and Copy and Paste copy them. A copy gets a new id, and one made beside its source gets a numbered name.

## Creating and editing

- The `+` button creates an asset in the folder the list shows: the Assets menu's Create items.
- A right click in either pane opens the Edit menu's Cut, Copy, Paste, Duplicate, Rename and Delete, then the Assets menu's items for the selected files and the open folder.
- Cut, Copy, Paste, Duplicate and Delete are the Edit menu's commands. They act on the whole selection, here on the selected files and folders, and have the same keys as in the Hierarchy. While a text field has the keyboard, the keys are the field's.

## Search

The search box takes the words [Windows](/docs/core/Windows.md#search-fields) lists. Its hits are files, folders and sub-assets of the whole project, shown as rows with their paths or as cells. Escape ends the search and shows the selected hit's folder.

## Keys

| Key | Command |
|---|---|
| Down, Up | The next and the previous row. In the grid, the cell below and above |
| Shift+Down, Shift+Up | Extend the selection |
| Right, Left | In the tree: open or close the folder, or step into or out of it. In the rows: unfold or fold the file's sub-assets. In the grid: the next and the previous cell |
| Ctrl+Right, Ctrl+Left | Unfold or fold the selected file's sub-assets |
| Tab | The other pane |
| F2, Enter on macOS | Rename |
| Enter, Cmd+Down on macOS | Open |
| Backspace, Cmd+Up on macOS | The parent folder |
| Ctrl+X, Ctrl+C, Ctrl+V | Edit/Cut, Edit/Copy, Edit/Paste |
| Ctrl+D | Edit/Duplicate |
| Ctrl+Backspace, Delete | Edit/Delete |
| Escape | End the search |

## Cost

- Each pane keeps a flat list of its rows and draws only the ones on screen, in the grid a row of cells at a time. A cell or a row asks for its thumbnail and its sub-assets only while it is on screen.
- The tree's rows are kept between frames. They are built again when a folder is opened or closed, when the editor changes files, and twice a second for changes made outside the editor. That check looks at the open folders only: a closed folder keeps its arrow from the last time it was read.
- A folder's listing is cached (`project_dir_cache.odin`). Twice a second the cache checks the folder's modification time, and reads the folder again only when it moved.
