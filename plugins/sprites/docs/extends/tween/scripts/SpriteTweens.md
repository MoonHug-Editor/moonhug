---
title: "Sprite tweens"
description: "One-line tweens of a SpriteRenderer's color and alpha, from code"
weight: 10
tags: ["sprites", "tween", "scripts"]
---

One-line tweens of a [SpriteRenderer](../../../../components/SpriteRenderer.md), from the plugin's `tween` subpackage. Needs the tween plugin.

## Example

```odin
import sprites_tween "moonhug:packages/sprites/tween"

sprites_tween.alpha(ghost, 0, 0.5)                                            // fade out
sprites_tween.color(enemy, {1, 0, 0, 1}, 0.1, opt = {cycles = 2, cycle_mode = .Yoyo})  // flash red
```

## Calls

| Call | Animates |
|---|---|
| `sprites_tween.color(object, to, timing, ease, opt)` | the SpriteRenderer's `color` |
| `sprites_tween.alpha(object, to, timing, ease, opt)` | its alpha alone, the color staying what it is |

- `timing` is seconds or a `tween.Settings`, and `ease` and `opt` work as for every one-line tween ([Tweens from code](/plugins/tween/docs/concepts/TweensFromCode.md)).
- Each returns a `tween.Handle`.
- The tween starts from the current color, and ends when the SpriteRenderer or its object goes.

## See also

- [API reference](/docs/reference/packages/sprites/tween.md) of the `sprites/tween` package, `color` and `alpha` with links to the code.
