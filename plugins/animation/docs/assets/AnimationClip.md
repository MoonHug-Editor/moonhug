---
title: "Animation clip"
description: "A .anim file or a clip inside a glTF model: keyframed channels, with import settings baked into the artifact"
weight: 10
tags: ["animation", "assets"]
---

A clip is keyframed animation: channels that move transforms and component fields over time. It is a `.anim` file, or a clip inside a glTF model that plays without being extracted. Both are imported assets: their settings live in the `.meta` and are baked into the artifact the runtime loads.

## Example

- Assets, Create, Animation makes `New Animation.anim`, an empty clip to edit in the [Animation window](../windows/AnimationWindow.md).
- A glTF model with animations lists its clips under it in the project view, `UAL1_Standard / Walk_Loop` for instance. A clip field takes them directly.

## Import settings

Shown in the Project Inspector when the clip is selected, applied with Apply.

| Setting | Default | What it does |
|---|---|---|
| `wrap` | Once | Once holds the final pose, Loop restarts. Every state that says Default plays this way. |
| `frame_rate` | 60 | The frame grid the Animation window snaps keys and the playhead to. Authoring only: playback is continuous in seconds. |
| `cycle_offset` | 0 | Where in a loop sampling starts, as a fraction of the clip. 0.5 starts halfway, so two characters sharing one walk do not march in step. |
| `trim_start`, `trim_stop` | 0, 0 | The part of the source clip to keep, in source seconds. A stop at or before the start keeps the whole clip. |

The settings live in the `.meta` rather than the `.anim` because a clip extracted from a model is a generated file: extracting again rewrites it, and the settings have to survive that. A `.anim` holds only `length` and `channels`.

## Artifact

- The importer bakes the trim: it drops the keys outside the range, moves the times to start at 0, and keeps an interpolated key at each cut, so a cut between keys starts on the value the clip had there. Nothing pays for the trim at runtime.
- `cycle_offset` is applied where every clip is sampled, so the Animation component, the editor preview and a timeline track all honour it.
- The runtime loads the artifact and never opens the `.meta`.

## Clips inside a model

- The mesh importer bakes each of a glTF model's animations to its own sub-asset file beside the model's artifact ([Sub-asset files](/docs/core/AssetPipeline.md#sub-asset-files)), and lists the clips in the model's settings with an id and a name.
- A clip is named by `{model guid, clip id}`. That is what a clip field stores. A `.anim` is `{its guid, 0}`, so one field takes both.
- The id is given at the first import and kept across imports by matching the clip's name.
- In the project view a model expands to its parts and its clips. A clip row drags onto a clip field, and the picker lists clips as `Model / Clip`.
- Selecting a clip under a model shows the model's import settings and, below them, that clip's own settings. They live in the clip's entry in the model's `.meta` and bake on Apply.
- The Preview pane poses the model's skeleton with the clip, playing or scrubbed by a slider. The project grid shows each clip at its midpoint.
- A clip that disappears from the model, renamed in the modelling tool for instance, stays in the list as an orphan so references to it keep resolving. Its section offers to remap it onto one of the model's current clips, which then takes over its references.
- A model clip is read-only. Assets, Extract Assets writes an editable `.anim` copy.
- What lands in the repository is the model and a few lines of its `.meta`. The curve data stays in `library/` and is rebuilt from the model on any machine.
- An export ships only the clips something references. A model under a `resources` folder ships every clip.

## In the editor

- The Project Inspector shows the import settings and the Preview pane.
- The [Animation window](../windows/AnimationWindow.md) edits a `.anim` through the component that plays it. A model clip opens read-only there.

## From code

A clip is referenced by an `engine.PPtr` field tagged `ext:"anim"`, the way the Animation component's `clip` is. Play one with `animation_play_clip` or `animation_cross_fade` ([Animation](../components/Animation.md), "From code").

## Settings it does not have

A setting that does nothing is worse than a missing one, so these wait for the system behind them:

- **Mirror** needs a left and right bone mapping.
- **Root motion** needs a root motion system.
- **Additive reference pose** needs additive layers. Layers override.

## See also

- [Clip format](../concepts/ClipFormat.md): the channels, value kinds, lanes and interpolation a clip stores.
