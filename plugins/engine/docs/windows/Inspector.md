---
title: "Inspector"
description: "The selected objects' components: every field edits with undo and prefab overrides, across a multi-selection, with Add Component and a padlock"
weight: 20
tags: ["engine", "editor", "windows"]
path: engine/windows
---

The selected objects' components, one section each, with every field editable. Several Inspector windows can be open.

## Editing

- Every field edit is one undo step and records a prefab override on an instance ([Undo](/docs/core/Undo.md)).
- With several objects selected, every field edits the whole selection, and a field whose values differ shows a dash ([Multiselection](/docs/core/Multiselection.md)). The header states the count.
- Add Component opens a searchable popup over the Component menu: the tree one level at a time, or, while the search has text, one flat list of every component that matches. Up and Down move the highlight, Enter adds it.
- A component's header menu has Reset, Copy Component, Paste Component as New and Paste Component Values.

## The padlock

The padlock in the tab bar keeps the window on what it shows while the selection moves on, so two objects can be compared side by side ([Windows](/docs/core/Windows.md), "Window locks").

## See also

- [Inspector](/docs/core/inspector/_index.md), how fields draw and how a plugin adds its own drawers.
