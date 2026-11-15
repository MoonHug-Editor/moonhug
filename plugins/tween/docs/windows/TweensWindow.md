---
title: "Tweens"
description: "Lists every running tween with its object, clock, time and state, and pauses, completes or stops one"
weight: 20
tags: ["tween", "editor", "windows"]
---

Lists every running tween while a game plays. Open it from Window, Animation, Tweens.

| Column | Shows |
|---|---|
| # | The run's slot. |
| Tween | The type of the run's root node: the node of a one-line tween, `Parallel` for a sequence built from code, `TweenCallback` for a delay. |
| Object | The object the run animates, and the object it is bound to when that is another one. |
| Clock | The clock the run ticks on, with the run's own time scale when it is not 1. |
| Time | Seconds advanced, as a bar against the run's length when the length is known. |
| State | `running`, `paused`, `waiting` (held by `tween.wait_for`) or `done, held`. |

- Pause, Complete and Stop act on one run, the way `tween.set_paused`, `tween.complete` and `tween.stop` do.
- Stop All stops every run.
- The list is what `tween.run_infos()` returns, so a game can show the same.
