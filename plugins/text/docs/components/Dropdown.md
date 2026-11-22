---
title: "Dropdown"
description: "A control that shows one of a list of options and opens the list to pick another, and DropdownItem, a row of the list"
weight: 20
tags: ["text", "mhgui", "components", "dropdown", "select", "combo box"]
---

A control that shows one of a list of options and opens the list to pick another. GameObject, UI, Dropdown creates one with every node it needs. It is a control of the text plugin, built on the mhgui plugin's Selectable.

## Example

```
Dropdown          RectTransform, CanvasRenderer, UiShape, Dropdown
├── Label         RectTransform, CanvasRenderer, Text
├── Arrow         RectTransform, CanvasRenderer, Text
└── Template      (inactive) RectTransform, CanvasRenderer, UiShape, LayoutGroup, ContentSizeFitter
    └── Item      RectTransform, CanvasRenderer, UiShape, DropdownItem
        ├── Checkmark     RectTransform, CanvasRenderer, UiShape
        └── Item Label    RectTransform, CanvasRenderer, Text
```

- The Label shows the chosen option.
- The Template is the list as it looks, with one Item. It stays inactive. The open list is a copy of it with a copy of the Item for each option.

## Properties

`interactable`, `transition`, `target_graphic`, `colors`, `sprites` and `navigation` are what every control has, as on a [Button](/plugins/mhgui/docs/components/Button.md).

| Field | Default | What it does |
|---|---|---|
| `options` | empty | The choices, in the order the list shows them. |
| `value` | 0 | The chosen option, counted from 0. |
| `caption` | none | The node with the Text that shows the chosen option. |
| `template` | none | The list: an inactive node with one DropdownItem somewhere under it. |

## DropdownItem

One row of the list. It is a control too, so it has the fields above: its colours are the row's look at rest, under the pointer and selected.

| Field | What it does |
|---|---|
| `label` | The node with the Text that shows the row's option. |
| `checkmark` | A node that is active only on the row of the chosen option. |

## Behavior

- A click on the dropdown, or the submit key while it is selected, opens the list.
- The open list draws over everything else on its canvas, and its rows take the pointer first (its `z_index` is raised by 1000).
- A click on a row, or the submit key on the selected row, picks its option and closes the list. `changed` is set when the value is another one.
- Opening selects the row of the chosen option, so the arrow keys walk the rows from there.
- A press anywhere else closes the list and picks nothing, and presses nothing else: while the list is open a node that takes the pointer covers the canvas under it.
- Escape closes the list. So does the selection moving off it, by a direction key at the list's end that finds another control, or by code.
- The Template is an ordinary subtree. The menu's one stacks its rows with a LayoutGroup and grows with a ContentSizeFitter. A ScrollRect in the Template makes a long list scroll.

## From code

```odin
import text "moonhug:packages/text"

@(update)
quality_tick :: proc(dt: f32) {
	_, quality := engine.transform_get_comp(quality_node, text.Dropdown)
	if text.dropdown_changed(quality) do apply_quality(int(quality.value))
}
```

| Proc | What it does |
|---|---|
| `dropdown_changed` | True on the frame the value changed. |
| `dropdown_option` | The chosen option's string. |
| `dropdown_set_value` | Chooses an option. Sets `changed` when it is another one. |
| `dropdown_set_options` | Replaces the options. The value stays, kept inside the new list. |
| `dropdown_show`, `dropdown_hide`, `dropdown_is_open` | Open, close and ask. |

Poll from an `@(update)` proc at order 0 or later: the dropdown updates at order -99.

## Limits

- Options are strings. A row has no picture of its own per option.
- The list opens where the Template sits, under the control in the menu's one. It does not flip above a control at the bottom of the screen.
- A UiMask above the dropdown clips its open list.
- Options changed while the list is open show the next time it opens.
