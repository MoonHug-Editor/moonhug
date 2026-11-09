---
title: "Roadmap"
description: "The UI controls and features that come next, ordered by what they unblock"
weight: 900
tags: ["mhgui", "roadmap"]
---

What the mhgui plugin does not do yet, ordered by what unblocks the most next.

1. **Toggle and Slider**, on the selectable base Button established, and a ToggleGroup for radio behavior.
2. **ScrollRect with a rect mask.** The first component that needs clipping in the canvas collector. Open: a scissor rect per draw call or a clip in the shader, and whether nested masks work from the start.
3. **Keyboard and gamepad navigation** between selectables, explicit and automatic.
4. **Drag events and transitions.** Pointer drag on selectables, then sprite swap and animation transitions. Colour tint is the only one now.
5. **Image Filled type.** Radial and horizontal fills.
6. **InputField and Dropdown.** InputField needs caret and selection drawing in the text plugin. Dropdown composes Button, ScrollRect and a template, so it follows item 2.
7. **Layout extras**, low priority: content size fitter, aspect ratio fitter, child expand, start corner and axis for grids.
8. **Effects.** Outline and shadow as vertex modifiers on a Graphic, once the populate path takes a modifier pass.
