---
title: "Auto exposure"
description: "postfx_exposure: meters the scene's brightness on the GPU, by average or histogram, and adapts the exposure to it over time"
weight: 30
tags: ["postfx", "render-steps"]
---

`postfx_exposure` meters the scene's average brightness on the GPU, with no readback, and adapts an exposure to it over time. Its 1 by 1 `exposure` target holds the factor in red, its log2 in green and the metered average in blue. The bloom's bright pass and the tonemap multiply the scene by it. Reads `final`, the scene's HDR image.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `metering` | Center Weighted | Center Weighted counts the middle most, a tenth at the corners. Average counts every pixel the same. |
| `target` | 0.6 | The average brightness the exposure brings the scene to. A sunlit scene looks as it does without auto exposure, a darker one is lifted to it. |
| `min_ev`, `max_ev` | -4, 8 | The range of average brightness metered, in stops. At -4 a dark scene is lifted by about ten times at most. |
| `compensation` | 0 | Stops brighter or darker. |
| `speed_dark_to_light`, `speed_light_to_dark` | 3, 1 | How fast the exposure follows, per second, toward a brighter and a darker scene. |
| `histogram` | on | Meters the middle of a brightness histogram, between `histogram_low` and `histogram_high`. |
| `histogram_low`, `histogram_high` | 40, 95 | The percentiles of the image that count, so the darkest and brightest parts do not pull the exposure. |

## Metering

1. The scene's log2 luminance at 256 by 256, each texel averaging 16 filtered taps over its part of the image, so a small bright spot counts by its area at any view size, times its metering weight.
2. Reduced 256, 64, 16, 4, 1, the weighted values and the weights each averaged, so the last texel gives the weighted average.
3. With `histogram` on, the 64 by 64 level goes into a histogram instead: 256 bins from -8 to 16 stops. The average takes the bins between the two percentiles, so a dark border or the sun outside them does not move the exposure, and a bright lamp moves it only by its share of the image.
4. Adapted: the exposure that brings the average, clamped to `min_ev` and `max_ev`, to `target`, reached from last frame's at the speed for its direction, `1 - exp(-dt * speed)` in stops. Each view keeps its own last value. A view's first frame takes the target at once.

## Dark scenes

Metering by the average lifts a dark scene toward the target, and its brightest spots clip. A scene meant to look dark needs a higher `min_ev`, at -1 it is lifted by at most 1.2 times, or a negative `compensation`.
