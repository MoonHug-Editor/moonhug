---
title: "Post FX"
description: "Auto exposure, bloom, tonemap operators with colour grading and FXAA as render steps a pipeline places between the engine's scene steps and its final blit, each with its own settings"
weight: 10
tags: ["rendering", "plugins"]
---

The postfx plugin ships six render steps (plugins/engine/docs/RenderPipeline.md). The default pipeline places `postfx_motion_blur` and `postfx_dof` (both muted) right after `scene_taa`, and three of the others after them and before `scene_over`, which draws the gizmos onto the finished image, in this order, `postfx_exposure` muted:

| Step | Reads | Writes | What |
|---|---|---|---|
| `postfx_motion_blur` | `hdr` and `motion?` (optional) | `hdr:HDR` and a scratch target | each pixel smeared along how far it moved since last frame, with the camera and with the objects that moved |
| `postfx_dof` | `hdr` | `hdr:HDR`, a full-size and two half-size scratch targets | depth of field: the scene blurred by its distance from the focus, through a thin lens |
| `postfx_exposure` | `final` (the scene's HDR image) | `exposure:HDR@1px` and the metering's chain | the scene's average brightness metered, the exposure adapted to it over time |
| `postfx_bloom` | `final` and `exposure?` (optional) | `bloom:HDR@0.5` and two scratch targets | a bright pass above the threshold, then a horizontal and a vertical gaussian blur |
| `postfx_tonemap` | `final`, `bloom?` and `exposure?` (optional) | `post:LDR*` | the exposures, the bloom added, colour grading, then the operator: none, Reinhard, ACES or ACES Hill, then the lookup texture |
| `postfx_fxaa` | `final` | `aa:LDR*` | fast approximate anti-aliasing |

Each step reads the finished image so far (`reads="final"`, `engine.render_input`) and takes its own target from its declaration (`engine.render_target`), whose `*` makes it the new final, so the engine's `final_blit` copies whichever step ran last. Removing a step from the pipeline removes its effect: without `postfx_fxaa` the tonemap output is the final, without all three the scene's HDR image is, the engine's own look. The tonemap adds bloom only when a bloom step ran before it in the lane: its `bloom` read is optional, and the bloom image already holds the light to add, the strength applied, so the tonemap needs nothing else from the bloom step. Without an exposure step the auto exposure is 1.

## Settings

Per placed step, in the Render Pipeline window's settings pane, stored in the pipeline asset:

- `postfx_exposure`: `metering` (Center Weighted, the default: the middle of the image counts most, a tenth at the corners; or Average), `target` (the average brightness the exposure brings the scene to, 0.6: a sunlit scene looks as it does without auto exposure, a darker one is lifted to that), `min_ev` and `max_ev` (the range of average brightness metered, in stops: -4 to 8, so a dark scene is lifted by at most about ten times), `compensation` (stops brighter or darker), `speed_dark_to_light` and `speed_light_to_dark` (how fast it follows, per second: 3 toward a brighter scene, 1 toward a darker one), `histogram` (on by default: meter the middle of a histogram of the brightness, between `histogram_low` and `histogram_high` percent of the image, 40 to 95, so the darkest and the brightest parts do not pull the exposure)
- `postfx_bloom`: `threshold` (scene color above it blooms, as exposed), `strength` (how much the tonemap adds back, applied in the last blur pass), `clamp` (the brightest a scene pixel counts for, half-float range by default). The bright pass averages four taps per half-size pixel weighted by 1 / (1 + brightness) (Karis), so a lone very bright pixel cannot flare into a glowing block
- `postfx_motion_blur`: `intensity` (how much of each frame's motion the blur spans, 0.5: a shutter open for half the frame), `samples` (taps along the motion, 8), `max_blur` (the longest blur as a fraction of the view's height, 0.05), `camera` (blur with the camera's motion too, on)
- `postfx_dof`: `focus_distance` (the sharp distance, metres, 10), `focal_length` (mm, 50) and `aperture` (f-number, 5.6: a longer lens or a lower f-number blurs more either side of the focus, on a 24 mm sensor), `max_blur` (the widest blur as a fraction of the view's height, 0.03), `samples` (taps on each pixel's disc, 24)
- `postfx_tonemap`: `operator` (None, Reinhard, ACES, ACES Hill), `exposure` (multiplier before the operator, after the auto exposure), `grading` (Colour grading, below). ACES Hill is Stephen Hill's fit of the ACES transforms, the curve the Khronos glTF Sample Viewer uses: with exposure 1 / 0.6 it matches the Sample Viewer's default look
- `postfx_fxaa`: none

## Auto exposure

`postfx_exposure` meters on the GPU, with no readback:

- the scene's log2 luminance at 256 x 256 (`exposure_luminance`), each texel averaging 16 filtered taps over its part of the image, so a small bright spot counts by its area at any view size, times its metering weight
- reduced 256, 64, 16, 4, 1 (`exposure_reduce`), the weighted values and the weights each averaged, so the last texel divides to the weighted average
- with `histogram` on, the 64 x 64 level goes into a histogram instead (`exposure_histogram`: 256 bins over -8 to 16 stops, a tenth of a stop each, drawn at 16 x 16 with every texel counting the whole level by weight), and the 1 x 1 average takes the bins between the `histogram_low` and `histogram_high` percentiles of the image (`exposure_percentile`): a dark border or the sun outside that range does not move the exposure, and a bright lamp moves it only by its share of the image
- adapted (`exposure_adapt`): the exposure that brings the average to `target`, the average clamped to `min_ev` .. `max_ev`, reached from last frame's at the speed for its direction (`1 - exp(-dt * speed)`, in stops). Each view (target pool and camera) keeps its own last value, in two 1 x 1 targets used in turn. A view's first frame takes the target at once
- the result is the 1 x 1 `exposure` target: red the factor, green its log2, blue the average metered

The bloom's bright pass multiplies the scene by it, so the threshold applies to the image as exposed and a lamp in a dark room blooms once the exposure has risen. The tonemap multiplies the scene by it before the manual exposure. A scene meant to look dark needs a higher `min_ev` (at -1 it is lifted by at most 1.2 times) or a negative `compensation`: metering by the average lifts it toward the target, and its brightest pools clip.

## Motion blur

`postfx_motion_blur` smears each pixel along how far it moved on screen since last frame, in the HDR scene image, writing back into `hdr`:

- an object that moved carries its motion vector where the engine's `motion_vectors` step drew it (`motion?`): that step runs with or without `scene_taa` in the lane
- everything else moved with the camera: the pixel's depth reprojected through last frame's camera, which the step keeps per view (target pool and camera). A view that skipped a frame or changed size blurs only its moved objects that frame. `camera` off blurs the moved objects alone
- the blur spans `intensity` of the motion, centred on the pixel (half before, half after), capped at `max_blur` of the view's height, in `samples` taps offset per pixel by noise so the steps do not band. Pixels that moved less than half a pixel are left alone
- each pixel gathers along its own motion only: a moving object blurs inside its silhouette and does not smear over what is behind it, and a static object in front of a moving background keeps its edge
- the motion is per frame as drawn, not per second: a faster frame rate shows less blur for the same speed, as a camera with the same shutter share would
- placed after `scene_taa` and before the rest of the post chain. `scene_over` comes last, so the gizmos stay sharp. The scene view's debug modes skip it

## Depth of field

`postfx_dof` blurs the HDR scene by how far each pixel is from the focus, writing back into `hdr`:

- the circle of confusion comes from a thin lens: the focal length, the aperture (focal length over f-number) and the focus distance give the circle a point at the pixel's view depth makes on a 24 mm sensor, in pixels of the half-size image, negative in front of the focus and positive behind it, capped at `max_blur` (`dof_coc`). The half-size image averages each 2 x 2 block's colour and takes the circle of its nearest pixel, so a near object keeps its spread
- each half-size pixel gathers `samples` taps on a disc of the widest radius (a golden-angle spiral, turned per pixel by noise). A tap counts where its own circle, or the pixel's, reaches it: a blurred near object spreads over its sharp neighbours, and a sharp object does not bleed into a blurred one behind it (`dof_bokeh`)
- the combine takes the sharp scene where the circle is under half a pixel and the blur, read in a 4-tap tent, where it is two pixels or more, blended between (`dof_combine`)
- the sky is at the far plane: it blurs when the focus is near, as a camera's would
- placed with the motion blur, after `scene_taa`. `scene_over` comes last, so the gizmos stay sharp. The scene view's debug modes skip it. The focus follows the step's settings, a Volume can move it per place

## Colour grading

The tonemap step's `grading`, applied in its one pass. Every default leaves the colour as it is:

- in linear light, before the operator: white balance (`temperature` warmer or cooler, `tint` greener or more magenta, each -100 to 100) and `color_filter` as one 3 x 3 matrix, then `contrast` (-100 to 100) around middle grey (0.18) in log2, then `hue_shift` (degrees, a turn around the grey axis) and `saturation` (-100 greyscale to 100 twice as colourful) as a second matrix
- white balance corrects for light of a cast: `temperature` 100 treats the scene's white as light of 13000 K and adapts it to the black-body curve's 6500 K (Bradford, along the Planckian locus), -100 as 3250 K. `tint` moves that white across the curve
- after the operator, in display (sRGB) values: `lut`, a lookup texture, blended in by `lut_contribution`. It is a strip of N squares N texels on a side (1024 x 32 for N = 32): red runs across each square, green down it, blue picks the square left to right. `assets/neutral_lut_32.png` changes nothing (within 8-bit rounding): take a screenshot, grade it in an image editor, apply the same adjustments to the neutral strip, and assign the result. A texture of another shape is not applied, with one warning

The matrices are built on the CPU per draw (`grading_matrices`), so the shader costs two matrix multiplies whatever is set.

## The shaders

`assets/resources/shaders/*.glsl` are ordinary fragment shaders compiled by the shader importer, registered as fullscreen shaders through `engine.shader_load_fullscreen` (the fullscreen vertex stage gives them `frag_uv` only). Inputs are samplers at `set = 2`, the property block at `set = 3, binding = 1`: a `vec4 params`, more for the tonemap and the adaptation. They sit under `resources` so an export ships them, since nothing in a scene references them.

## Removing the plugin

Delete the `moonhug/packages/postfx` link and build. No engine file knows the plugin. A pipeline that placed its steps warns once that they are not installed and renders without them.
