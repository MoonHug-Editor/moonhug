# Multiselection

Unity-style multi-selection in the hierarchy, scene view and project view.
Selection only — **no multiedit yet**: the inspector always shows the ACTIVE
object/file (the most recently selected one) and says "N selected" when more
are.

State lives in `editor/selection.odin`: an ordered set per domain (scene
Transform_Handles, project paths) where the LAST item is the active one.
Dead handles are pruned each frame; `projectViewData.selectedFile` remains
the active project path, so single-target code paths didn't change.

## Interactions

Everywhere (hierarchy rows, scene-view picking, project list rows):

- **click** — select only this
- **cmd/ctrl-click** — toggle in/out of the selection (the added item
  becomes active; clicking empty scene space with cmd held does NOT clear)
- **shift-click** — range from the active row over the VISIBLE rows,
  replacing the selection (hierarchy + project list; not scene picking)
- **shift + up/down** — extend the selection row by row
- **Escape** (scene view) — clear

The active row is outlined in the hierarchy when more than one is selected.
The project status line shows the count.

## Actions on the selection

- Hierarchy context menu: **Delete Selected** / **Duplicate Selected** act on
  every eligible selected object (scene roots and nested-scene contents are
  skipped), as ONE undo step. Children of selected ancestors are skipped —
  the ancestor's operation covers them.
- **Edit/Toggle Transform Active** (Alt+Shift+A) toggles all selected, one
  undo step.
- Right-click on a selected row keeps the selection (menu acts on all of
  it); on an unselected row it selects just that row first.
- Single-target actions use the active item: rename, gizmo, frame (F),
  Create Empty Child/Parent, project open/rename/Extract/Scene Variant,
  drag-drop payloads.

## Not yet (follow-ups)

- Multiedit (editing shared fields across the selection)
- Gizmo moving the whole selection (active object only today)
- Rubber-band box select in the scene view
- Multi-path drag-drop from the project view
