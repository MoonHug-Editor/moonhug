---
title: "Folder Structure"
description: "What each top-level folder holds, and the derived-data cache in library/"
weight: 1
tags: ["build", "assets"]
---

## Folders
- prebuild - generator folder
  - separate program that runs even before anything compiles
- editor - the editor shell
  - editor is the top level package, composed with the installed plugins through generated files and `moonhug:registration`, its subpackages are the shell's mechanisms (inspector, undo, viewport, assets, menus)
- packages - one link per installed plugin into `plugins/` at the repo root, the plugin reached as `moonhug:packages/<name>`
- host - the packages the game and the editor both stand on, none of them imports the engine
  - core, log, serialization, gizmos, gfx, input, assets, catalog, crash_journal, imported as `moonhug:host/<name>`
- registration - generated only: the registration bundle (packages, phases, type registration) the editor and the tests import as `moonhug:registration`
- builds folder - build results with runnable application
- external - external dependencies folder
- library - derived-data cache (Unity's Library model, see [library](#library)). Safe to delete, rebuilt on the next run
- ProjectSettings - settings about the PROJECT, committed: `mcp.json` and one `<slug>.json` per @(project_settings) tab
- UserSettings - per-developer editor state, never committed (Unity's UserSettings): window geometry, open scenes and windows, panel visibility, theme, grid and snap, selected run config, and in `external_tools.json` the optional command Edit Script runs to open a file at a line (`script_editor`, such as `zed {file}:{line}`, empty opens the file with the app the OS associates with it) and the URL template the documentation site links source locations to (`source_url`, such as `vscode://file/{file}:{line}`, empty links to GitHub at the current commit). A `@(user_settings)` with `tab="..."` is also a tab of the Settings window. The editor writes each settings file with its defaults on the first start. Safe to delete, the editor writes defaults on the next run

The folders above are inside `moonhug/`. Next to it, at the repo root:

- plugins - every plugin, enabled by its link in `moonhug/packages/` ([Plugins](Plugins.md))
  - engine - the engine plugin: scenes, transforms, components, rendering, `package engine`, imported as `moonhug:packages/engine` by the game and the editor
    - editor - the engine's editor half, one subpackage per folder (scene_views, scene_tools, drawers, importers, previews, undo, undo_ops, sim_world, mcp_tools, mesh_editor, host), never linked into game binaries (the app runs the catalog pipeline only). The write side of the asset pipeline is the shell's editor/assets over the host package host/assets, `editor/importers` holds the engine's importers
    - gen - the engine's generators, compiled into the prebuild
    - docs - the engine's documentation pages, mounted on the site at `/plugins/engine` ([Components](../../plugins/engine/docs/Components.md) is the first)
  - app - the game: a runnable plugin with no editor dependencies outside its own `editor/`

## Library

Everything under `library/` is derived data — never a source of truth, safe to delete, rebuilt from assets + metas on the next run (Unity's Library contract).

- `library/artifacts/<xx>/<key>.bin` - import artifacts, **content-addressed**: the 128-bit key hashes every input that shapes the importer's output — source bytes, import settings, the importer's version constant, the artifact format version. Invalidation is automatic (any changed input is a different key), toggling a setting back is a cache hit on the old artifact instead of a re-import, and keys are machine-independent (a shared team cache stays possible). `<xx>` is the key's first two hex chars (Unity's fan-out layout)
- `library/artifact_db.json` - the index: guid → current artifact key + source file stamp + settings hash, so an unchanged file costs one stat per scan, never a rehash
- `library/thumbnails/<xx>/<guid>.thumb` - project view thumbnails (raw RGBA + a stamp header), guid-keyed so a changed asset overwrites its entry in place. Written asynchronously after generation (fence-polled GPU readback, no sync stalls), loaded instead of re-rendering on the next session. Deleted assets' entries are pruned at editor startup
- `library/state_cache/` - editor session state (the Play button's live-scene snapshot)
- garbage collection runs with the import pass: artifact files no index entry references are deleted
- importers carry a version constant (`_importer_version`) — bump it when an importer's output changes and exactly its artifacts re-import, nothing else
