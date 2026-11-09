---
title: "Input Actions"
description: "The debug window: the pushed contexts and every action's live state, with buttons to push and pop contexts"
weight: 10
tags: ["input", "editor", "windows"]
---

Shows the input actions while the game runs. Open it from Window, Input, Input Actions.

- The Input setting's asset, with a Select button that selects it for editing.
- Every context of the asset with a Push or Pop button, so a stack can be tried without the game code that would push it.
- The pushed contexts from the top down and, under each, its actions with their live state, pressed, down or released, their value and their keys.
- An action whose keys a context above consumes shows greyed out: it cannot answer.

The values are the running game's, so the window fills while the game runs. `debug_rows()` is the data behind it.
