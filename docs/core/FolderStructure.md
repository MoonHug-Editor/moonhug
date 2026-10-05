---
title: "Folder Structure"
description: "What each top-level folder holds, and the derived-data cache in library/"
weight: 1
tags: ["build", "assets"]
---

## Folders
- prebuild - generator folder
  - separate program that runs even before anything compiles
- editor, *_editor - editor folders
  - editor is top level package with dependencies on everything else
  - engine_editor is the engine's editor half — subpackages pairing with engine ones (engine_editor/asset_pipeline is the write side of engine/asset_pipeline.odin: importers, import drivers, AssetDB scanning, meta writing) — never linked into game binaries (the app runs the catalog pipeline only)
- app folder - game code
  - app package should not have any editor dependencies
- engine - core dependency for app and editor
- builds folder - build results with runnable application
- external - external dependencies folder
- library - derived-data cache (Unity's Library model, see [library](#library)). Safe to delete, rebuilt on the next run
- ProjectSettings - settings about the PROJECT, committed: `mcp.json` and one `<slug>.json` per @(project_settings) tab
- UserSettings - per-developer editor state, never committed (Unity's UserSettings): window geometry, open scenes and windows, panel visibility, theme, grid and snap, selected run config. Safe to delete, the editor writes defaults on the next run

## Library

Everything under `library/` is derived data — never a source of truth, safe to delete, rebuilt from assets + metas on the next run (Unity's Library contract).

- `library/artifacts/<xx>/<key>.bin` - import artifacts, **content-addressed**: the 128-bit key hashes every input that shapes the importer's output — source bytes, import settings, the importer's version constant, the artifact format version. Invalidation is automatic (any changed input is a different key), toggling a setting back is a cache hit on the old artifact instead of a re-import, and keys are machine-independent (a shared team cache stays possible). `<xx>` is the key's first two hex chars (Unity's fan-out layout)
- `library/artifact_db.json` - the index: guid → current artifact key + source file stamp + settings hash, so an unchanged file costs one stat per scan, never a rehash
- `library/thumbnails/<xx>/<guid>.thumb` - project view thumbnails (raw RGBA + a stamp header), guid-keyed so a changed asset overwrites its entry in place. Written asynchronously after generation (fence-polled GPU readback, no sync stalls), loaded instead of re-rendering on the next session. Deleted assets' entries are pruned at editor startup
- `library/state_cache/` - editor session state (the Play button's live-scene snapshot)
- garbage collection runs with the import pass: artifact files no index entry references are deleted
- importers carry a version constant (`_importer_version`) — bump it when an importer's output changes and exactly its artifacts re-import, nothing else
