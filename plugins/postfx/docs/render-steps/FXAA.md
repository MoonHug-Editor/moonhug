---
title: "FXAA"
description: "postfx_fxaa: fast approximate anti-aliasing on the final LDR image"
weight: 60
tags: ["postfx", "render-steps"]
---

`postfx_fxaa` smooths jagged edges in the LDR image with fast approximate anti-aliasing. Reads `final`, writes `aa`, the new final. It has no settings, and is not in the default pipeline: add it after the tonemap.
