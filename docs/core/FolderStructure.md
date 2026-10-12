---
title: "Folder Structure"
description: "What each top-level folder holds, and the derived-data cache in library/"
order: 2
tags: ["build", "assets"]
path: general/architecture
---

## Folders

```
moonhug/                    ← the editor's project
  prebuild/                 ← generator folder: a separate program that runs even before anything compiles
  editor/                   ← the editor shell: the top-level package, composed with the installed plugins through generated files and moonhug:registration
  packages/                 ← one link per installed plugin into plugins/ at the repo root:  import "moonhug:packages/<name>"
  host/                     ← the packages the game and the editor both stand on, none imports the engine:  import "moonhug:host/<name>"
  tests/                    ← the editor's own test suite, importing no plugin
  registration/             ← generated only: the registration bundle (packages, phases, type registration):  import "moonhug:registration"
  builds/                   ← build results with runnable application
  external/                 ← external dependencies folder
  library/                  ← derived-data cache (see Library below). Safe to delete, rebuilt on the next run
  ProjectSettings/          ← settings about the PROJECT, committed: mcp.json and one <slug>.json per @(project_settings) tab
  UserSettings/             ← per-developer editor state, never committed. Safe to delete, the editor writes defaults on the next run
plugins/                    ← next to moonhug/, at the repo root: every plugin, enabled by its link in moonhug/packages/ (see Plugins)
  engine/                   ← the engine plugin: scenes, transforms, components, rendering:  package engine
  app/                      ← the game: a runnable plugin with no editor dependencies outside its own editor/
```

## Library

Everything under `library/` is derived data — never a source of truth, safe to delete, rebuilt from assets + metas on the next run.

- `library/artifacts/<xx>/<key>.bin` - import artifacts, **content-addressed**: the 128-bit key hashes every input that shapes the importer's output — source bytes, import settings, the importer's version constant, the artifact format version. Invalidation is automatic (any changed input is a different key), toggling a setting back is a cache hit on the old artifact instead of a re-import, and keys are machine-independent (a shared team cache stays possible). `<xx>` is the key's first two hex chars (fan-out layout)
- `library/artifact_db.json` - the index: guid → current artifact key + source file stamp + settings hash, so an unchanged file costs one stat per scan, never a rehash
- `library/thumbnails/<xx>/<guid>.thumb` - project view thumbnails (raw RGBA + a stamp header), guid-keyed so a changed asset overwrites its entry in place. Written asynchronously after generation (fence-polled GPU readback, no sync stalls), loaded instead of re-rendering on the next session. Deleted assets' entries are pruned at editor startup
- `library/state_cache/` - editor session state (the Play button's live-scene snapshot)
- garbage collection runs with the import pass: artifact files no index entry references are deleted
- importers carry a version constant (`_importer_version`) — bump it when an importer's output changes and exactly its artifacts re-import, nothing else
