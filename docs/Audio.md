# Audio

Everything lives in `moonhug/packages/audio` — the engine has no audio code.
Backend: SDL3_mixer (`vendor:sdl3/mixer`, needs `brew install sdl3_mixer`).

## Pipeline

- The importer decodes the source (`.wav`, `.mp3`, `.ogg`) to float32 PCM,
  applies `AudioSettings.volume`, and writes a float32 WAV artifact.
- Playback loads the ARTIFACT, never the source — every consumer hears the
  mastered result.
- `volume` in the import settings is the mastering gain, baked into the
  artifact's samples. Changing it re-imports under a new artifact key, and
  changing it back is a cache hit on the old artifact.

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
baked gain), `loop`, `play_on_awake`.

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

## Semantics

- One `mix.Track` per playing source, created on first play, destroyed with
  the component.
- Load type is decompress-on-load only (the artifact is predecoded into
  memory). Streaming and compressed-in-memory are not implemented.
- No mixer groups, effects or spatialization yet — SDL3_mixer has the
  primitives (tags, `Point3D`, stereo gains) when they're needed.
