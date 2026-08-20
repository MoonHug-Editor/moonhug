# Audio

Everything lives in `moonhug/packages/audio` — the engine has no audio code.
Backend: SDL3_mixer (`vendor:sdl3/mixer`, needs `brew install sdl3_mixer`).

## Pipeline

- The importer decodes the source (`.wav`, `.mp3`, `.ogg`) to float32 PCM,
  applies the settings, and writes a float32 WAV artifact.
- Playback loads the ARTIFACT, never the source — every consumer hears the
  mastered result.
- `volume` in the import settings is the mastering gain, baked into the
  artifact's samples. `normalize` scales the peak to 1 first, then volume
  applies. Changing either re-imports under a new artifact key, and
  changing back is a cache hit on the old artifact.

## Runtime

- `clip_load(guid) -> (^Audio_Clip, bool)` — guid-keyed cache over
  `mix.Audio` instances, mirror of the engine's texture cache. Imports on
  demand when the artifact is missing.
- The mixer device is created lazily on first use. Headless contexts
  (tests, tooling) fall back to a deviceless mixer — loading works, nothing
  is audible.
- A reimport evicts the cached clip (pipeline reimport hook), so a settings
  change takes effect on the next play without a restart. Playing tracks
  detach first and play-on-awake sources restart with the new master.

## AudioSource

Unity-literal component: `clip` (`Asset_GUID` with picker + drag-drop
filtered to audio extensions), `volume` (per-instance multiplier over the
baked gain), `pitch` (playback frequency ratio), `mute`, `loop`,
`play_on_awake`, and the spatial trio `spatial_blend` / `min_distance` /
`max_distance`.

- The `@(update)` subscriber starts play-on-awake sources and applies live
  volume changes. It runs in play mode (editor) and every frame (app).
- Disabling a source stops it, re-enabling replays when `play_on_awake` is
  set.
- `audio_play(src)` / `audio_stop(src)` / `audio_is_playing(src)` for code.
- Exiting play mode stops all tracks.
- The component inspector carries Play/Stop buttons (`@(inspector_button)`)
  for auditioning a source without entering play mode.

## Preview

Selecting an audio file shows Play/Stop buttons in the Project Inspector's
bottom Preview section — one shared preview track, independent of any
component (`preview_play(guid)` / `preview_stop()`). Registered by the
`packages/audio/editor` subpackage through `inspector.mapAssetPreview`
(extension-keyed preview pane — open to any package).

## Spatial

`AudioListener` is the ear — a fieldless component (usually on the camera),
the first enabled one wins. A source with `spatial_blend > 0` attenuates
and pans relative to it every frame:

- Logarithmic rolloff (Unity's default): full volume inside
  `min_distance`, `min/d` beyond it, held constant past `max_distance`.
- Balance pan from the listener-space azimuth (x/z plane) — vertical
  offset attenuates but does not pan.
- `spatial_blend` lerps both effects between 2D (0) and full 3D (1).

The math is a pure proc (`spatial_gains`), unit-tested headless. Without a
listener every source plays 2D.

## Semantics

- One `mix.Track` per playing source, created on first play, destroyed with
  the component.
- Volume, pitch, mute and the spatial gains apply every frame — inspector
  edits are audible live.
- Load type is decompress-on-load only (the artifact is predecoded into
  memory). Streaming and compressed-in-memory are not implemented.
- No mixer groups or effects yet — SDL3_mixer has the primitives (tags)
  when they're needed.
