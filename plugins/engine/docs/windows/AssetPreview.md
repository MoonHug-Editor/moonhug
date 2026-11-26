---
title: "Asset preview"
description: "The preview at the bottom of the Project Inspector: textures with channels and mips, models, scenes, materials and clips in studio light, and a line of facts about each"
weight: 25
tags: ["engine", "editor", "windows", "assets"]
path: engine/windows
---

The Project Inspector shows a preview of the selected asset at its bottom, under the asset's fields. Its title bar has the asset's name on the left and the preview's controls on the right, and a line under the picture says what the asset holds. Drag the edge above the bar to resize the preview.

## Textures

| Control | What it does |
|---|---|
| R, G, B, A | The channels shown. One color channel alone shows as grey, and so does alpha alone. With A on, transparent parts show a checkerboard. |
| Mip | The mip level shown, when the texture has mips. Each level is half the size of the one above. |

The line gives the size, the format, the mip count and the memory the texture takes on the GPU. A texture the import scaled down shows its source size too. A selected sprite slice shows its crop and its size.

## Models, scenes and clips

Drag to turn the view, use the wheel to zoom, and double click to go back to the starting view and light. Hold Shift and drag to turn the studio light and its sky around the asset.

| Control | What it does |
|---|---|
| Floor | A plate under the asset, off at first. In studio light the key light casts the asset's shadow on it. |
| Light | On: studio light, a warm key light from the upper left and a soft fill, with a sky for reflections and ambient light. Off: one light from the camera, so every side the view turns to is lit. |

- The sky is the open scene's Environment when it has one, so a material looks as it does in that scene. With none, a neutral sky stands in.
- The light stays put as the view turns, so the shadow stays on the same side of the asset. A Shift+drag turns the key light, the fill, the shadow and the sky together.
- A model's line gives its vertices, triangles, materials and size, and its joints when it is skinned. A scene's gives its objects and its size, a clip's its length.
- A clip plays on its model's skeleton, with a play button and a slider to scrub it. While it plays the editor draws at its full frame rate.

## Materials

The material shows on a shader ball, a sphere, a cube or a plane, picked with the buttons on the title bar. The shader ball comes first: a ball with a slice cut off at an angle and a smaller ball inside the cut, on a short neck over a small base. Around the base sits a collar with a chamfered edge and a quarter cut out on the side the slice faces. One picture shows curved parts, flat parts at several angles and sharp edges. A material a scene file holds as a sub-asset gets the same preview. The choice is kept for every material. The light toggle works as for models, and a material has no floor. The line gives the shader and the surface.

## When it draws

A preview draws again only when its picture would change: another asset, a new pane size, the view turned, a control changed, the asset edited or reimported, or the scene's sky rebuilt. Otherwise it shows the picture it drew last, and costs nothing per frame.

The choices are kept for the person on this machine, in the Asset Preview user settings.
