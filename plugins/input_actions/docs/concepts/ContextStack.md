---
title: "The context stack"
description: "How pushed mapping contexts stack by priority, which context answers for a key, and what a context consumes from the ones below"
weight: 20
tags: ["input", "concepts"]
---

Which mapping context answers for a key.

## Pushing and popping

- Nothing resolves until a context is pushed.
- `context_push(name)` and `context_pop(name)` keep a stack ordered by priority, and a later push sits above an earlier one of the same priority.
- The game pushes Player at start, Vehicle when the player enters a car, Menu when a menu opens, and pops them on the way out. Nothing re-enables the context below, because it was never disabled.
- A popped context's actions read as released and zero.

## Who answers

For each key the highest pushed context that maps it answers. What a context takes from the contexts below is its Consume Input mode:

- **All** takes every key. A Menu context on top blocks all gameplay input.
- **Listed** takes only the keys of its actions marked Consume. A Gun context pushed over Player takes Fire's key and leaves movement to Player.
