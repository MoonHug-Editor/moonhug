---
title: "Engine as a Plugin"
description: "Plan: the editor becomes a generic shell for any Odin package, the engine becomes a regular plugin on it"
weight: 90
tags: ["design", "plugins", "editor", "engine"]
---

This is the plan for the README's optional goal: an editor that works on any Odin package with no engine code. The engine is a regular plugin in `plugins/engine` with its own generators and manifest, and its docs move into it in the last part of step 11. The editor becomes a shell you drop a package into.

## The result

A project holds a custom package and files in its `Assets/` folder. With no engine plugin installed, the editor still:

- shows the package's assets in the project view, imported into `Library/` by the importers the package registers
- inspects and edits the package's structs, with the package's own drawers through `@(property_drawer)`
- records every edit on the undo stack
- draws the package's handles and gizmos in a viewport, through `@(on_scene_handles)` and `@(on_draw_gizmos)`
- opens the package's views through `@(editor_window)`, and its menus, toolbar items and settings tabs through the existing attributes
- builds and runs the package through a run config the package registers, and ticks its `@(update)` procs under Simulate

Installing the engine plugin adds scenes, the hierarchy, components, the scene view's rendering, and the asset types the engine knows.

## Layers

```
game exe     core host ── engine plugin ── game plugins
editor exe   core host ── editor shell ── engine plugin ── game plugins
                                           └ engine/editor/   └ <plugin>/editor/
```

- **Core host** is `moonhug:host/core` today: application, phases, pools, the type registry, object refs. A shipped game and the editor both stand on it. It gains the JSON layer, so undo snapshots, settings and asset documents need nothing above it.
- **Editor shell** is the generic editor on the host. It declares the extension points plugins fill and compiles with zero plugins. Check: move every symlink in `moonhug/packages` aside, `make build` exits 0, move them back and build twice.
- **Plugins** each have a runtime part and an `editor/` subpackage linked only into the editor exe, the pattern integration subpackages already use. The engine is the first and largest plugin, with its `editor/` part in `plugins/engine/editor`.

The editor is not a plugin. A plugin is a distribution unit a project includes or leaves out, and the editor is always in the editor exe and never in the game exe. That choice is the build target's. The editor is also what the extension points extend, so it exists before any plugin registers into it.

## The boundary

The shell owns the mechanisms, plugins own what runs inside them:

| Shell | Engine plugin |
|---|---|
| window, dock, views, menus, toolbar, tab bars | scene view, hierarchy, game view |
| inspector reflection, field rows, undo recording | drawers for `Handle`, `PPtr`, `Asset_GUID`, `Ref`, `Curve`, `Gradient`, `Material` |
| undo stack, grouping, snapshots | undo operations on scenes, prefabs and nested overrides |
| viewport: camera, navigation, picking, overlay lines | render collectors that draw meshes, sprites and lights into it |
| `Assets/` and `Library/`, guid database, project view, thumbnails, importer registry | importers for meshes, textures, audio, scenes, and the asset types |
| run config protocol, Simulate controls and Game view focus | build and launch of the app, snapshot and restore of the world |
| settings windows, console, debug tooltips, dialogs, MCP | MCP tools that read scenes |
| prebuild, attributes, docs | the engine's generators in its `gen/` |

Imports go one way: the shell imports no plugin, plugins import the shell. `moonhug/tests/editor_boundary_contract_tests.odin` fails when a hand-written file under `moonhug/editor`, `moonhug/host` or `moonhug/registration` imports the engine. `editor/main.odin` may import `moonhug:registration`, the bundle that registers every installed package: it is the composition point.

## Where the code is today

Measured on 2026-10-05, non-generated files:

- 78 of 115 editor files import the engine. 72 of them through relative paths like `"../../engine"` instead of the `moonhug:` collection.
- The undo package is scene operations throughout: 80 distinct engine symbols, `nested_scene_record_*`, `prefab_propagate`, `scene_copy_subtree`. The stack is generic, no operation is.
- The inspector's engine use is the reference types: `Asset_GUID` 34 uses, `PPtr` 20, `Handle` 13, `Ref` 10, plus the Curve, Gradient and Material drawers.
- The top-level editor package leans on `Transform_Handle` (195), `Handle` (80), `TypeKey` (68), `ctx_world` (62), `pool_get` (50), `Asset_GUID` (47).
- `serialization` is a host package of its own. At measurement time it imported the engine for component and union serializers, and `core` had no JSON.
- `widgets`, `icons`, `node_canvas`, `preview`, `progress` and `mcp` import nothing from the engine.

## Steps

Each step leaves the editor building and the tests green, and each shrinks the contract test's list.

1. **Boundary test.** Done.
2. **Serialization audit.** Done, the numbers above.
3. **Collection imports.** Done. Every editor file and every generator imports the engine as `moonhug:packages/engine`.
4. **JSON layer into the host.** Done, and smaller than planned. `json_canonicalize_floats` and the settings persistence (`project_settings_*`, `user_settings_*`) live in `host/core`, `host/serialization` imports core instead of the engine, and the engine registers its own pointer types (`Curve`, `Gradient`) at `SerializationInit`. `test_host_packages_import_no_engine` keeps `core`, `log` and `serialization` free of the engine.
5. **Reference types stay, their resolution moves.** `Handle`, `PPtr`, `Ref`, `Ref_Local`, `Local_ID` and `Asset_GUID` are core vocabulary, and a generic editor draws them. What the drawers borrow from the engine is resolving them: the asset database (step 8), the world lookups behind the picker's Scene tab, and the request mailbox. Done so far: `Curve` and `Gradient` are core types (a plugin that wants its own curve registers its own type and drawer), the inspector mailbox and nested-host state are `core/inspector_state.odin`, and the sprite picker and Material drawers are `plugins/engine/editor/drawers`, registering through `inspector.add_property_drawer` and `inspector.add_asset_doc_hook` at EditorInit order 1. The world lookups behind the picker's Scene tab and a `Ref_Local` field go through `inspector.Object_Provider` (owner of a handle, its name, the scope local ids mint against, find objects of a key, has-component filter, ref tags), which `plugins/engine/editor/drawers/object_provider.odin` installs at EditorInit and `tests/common` installs for the test binary. `Found_Object` is a core type. Done.
6. **Undo operations out of the undo package.** Done. `Command` is a generated union: a type marked `@(undo_command)` with `apply_`, `revert_`, `destroy_` and `label_` procs in its file joins it (`prebuild/undo_command_gen`), with optional `scenes_`, `assets_` and `describe_`. The shell keeps the stack, groups, sessions, the owner stack, the selection snapshot and `Value_Command`, and resolves pooled targets through `undo.Target_Resolver`. The engine's commands are `plugins/engine/editor/undo_ops`, the recording helpers (`record_*`, `apply_to_prefab`) are `plugins/engine/editor/undo`, which also installs the resolver and re-exports the shell's API. Package names are unique program-wide, so that package is named `scene_undo` and is imported as `import undo "moonhug:packages/engine/editor/undo"`: engine-side code and plugin editors write `undo.push` and `undo.record_create` as one API. A command's package must not import `undo`, the generated file imports it. `editor/undo` left the list.
7. **Viewport.** A shell view with camera, navigation, picking and an overlay draw list. Handles and gizmos draw into it, and the scene view becomes its first consumer, adding rendering through the render collectors. In four parts: (a) the camera math (`Render_View`, `Ray`, `render_view_make`, `render_view_screen_ray`, `trs_matrix`, the ray casts) into core, done, (b) the gizmo vocabulary and buffer out of the engine so `host/gizmos` imports core and gfx only, done: the buffer is reached through a slot the engine points at its user context, the package asks a transform source and an image source the engine installs, and `gfx`, `input` and `gizmos` count as host packages, (c) the engine's tools out of the editor, done: the transform tool, picking, the selection outline and the camera and light gizmos are `plugins/engine/editor/scene_tools`, which also holds the generated gizmo dispatchers. They read the shell's selection and game view aspect through `viewport.Selection_Source`, which the editor sets at start. The gizmo visibility settings are `host/gizmos/settings.odin`, (d) the viewport view, done: `view_scene` and `gizmo_pass` are the shell's viewport and import no engine package. They reach the engine through `viewport.Viewport_Provider` (`editor/viewport`): render, pick, frame bounds, the tools' frame and the gizmo dispatch, which `scene_tools` installs from `@(init)`. The tool mode (`viewport.gizmo_mode`, `gizmo_space`, `gizmo_pivot`) is the shell's, the transform tool reads it. Check: `editor/handles` leaves the list, and a package with no engine draws a handle.
8. **Asset database into the host, pipeline into the shell.** The guid database and the pipeline's read half are the host package `host/assets`, since games read them too. Scenes index themselves through `asset_db_add_indexer`, caches clear through `asset_db_add_evict_hook`, and sub-assets and extra artifacts are declared by the importer (`Importer_Desc.sub_assets`, `artifacts`). The write half (scan, import, importer registry) is the shell package `editor/assets`, package name `asset_pipeline`, and the engine's importers are `plugins/engine/editor/importers`. The project view opens assets through `asset_pipeline.Asset_Actions` (open, open additive, create variant), which the engine installs. Thumbnails: the cache is the shell package `editor/thumbnails` (renderers register per extension through `thumbnails.register` and `register_sub`), and the engine's renderers, the inspector's asset previews and the preview world are `plugins/engine/editor/previews`. Done. Check: the project view lists a text file in a project with no engine.
9. **Run configs and Simulate as protocols.** The shell owns the dropdown, the alt-click, the Simulate controls and the Game view gating, and calls `@(phase)` hooks at start and stop. The engine's run config builds and launches the app, and its hooks snapshot and restore the world. The world is the provider `simulate.Simulate_World` (capture, restore, release, set_playing, tick, reset_time, select_restored), installed by `plugins/engine/editor/sim_world`. The run config subpackage stands on the leaf host package `host/catalog` only. Done. Check: a package with no engine builds and runs from the toolbar, and its `@(update)` procs tick under Simulate.
10. **Scene views out.** The hierarchy, the component inspector with its prefab logic, the rect tool, the GameObject and Component menus, multiselection of transforms and glTF extraction are `plugins/engine/editor/scene_views`, reached from the shell through `viewport.Scene_Views`. The shell keeps selection, the Edit menu, the Game view and the inspector, which ask the engine through `viewport.Document_Actions` (save, open paths, snapshot), `render_game` on the viewport provider, `inspector.Override_Provider` (is a field overridden, revert, apply, host) and the object provider. Parts 1 and 2 done, 24 → 2 files on the list. Part 3: the MCP tools that read or edit the world are `plugins/engine/editor/mcp_tools`, registered through `@(mcp_tool)`, and the transport, the shell's tools and the on/off switch (`mcp.mcp_settings`) stay in the shell. Part 4: `main.odin` boots and tears down the engine through `viewport.Host_Lifecycle` (boot, init, shutdown, release), which `plugins/engine/editor/host` installs from `@(init)`. Startup scenes open through `asset_pipeline.asset_open_additive`, File/Save Scene and Assets/Create/Scene are `plugins/engine/editor/scene_views`, and `project_chdir_root` is the host package `host/assets`. Done, 1 file on the list: `main.odin`, the composition point, which imports `moonhug:registration` (and `host/crash_journal`, a standard-library-only package not yet on the host list).
11. **The engine becomes `plugins/engine`.** In four parts: (1) the host packages out of the engine folder into `moonhug/host/<pkg>` and the generated bundle into `moonhug/registration`, done, (2) the engine's generators into `plugins/engine/gen/`, done: the five generators are one `engine_gen` package there, loaded like any plugin's `gen/` through the `moonhug/packages/engine` symlink and its `mh_plugin.json`, with every engine path they emit to as a constant at the top of `components_gen.odin`, (3) the engine into `plugins/engine`, done: the runtime is the plugin's root (`package engine`), the editor half is its `editor/` with the subpackages keeping their names, every plugin importing it lists `engine` in its `mh_plugin.json`, and imports are `moonhug:packages/engine` and `moonhug:packages/engine/editor/<pkg>`, (4) the docs split between the shell and the plugin. The boundary test is the shell rule in "The boundary" above, part of (3). Last, because before the list is empty it is a rename with the same coupling.

## The two hard points

- **The viewport** (step 7). Handles and gizmos today draw into the scene view the engine owns, and picking reads the engine's hit shapes. The shell needs the camera and the overlay without a renderer, and the engine needs to add meshes to it without owning it.
- **The object provider** (step 5). The picker's Scene tab and a `Ref_Local` field need "objects of this type", "name of this handle" and "mint a local id" from whatever owns the objects. With the engine installed that is the world and the scene manager, and without it the shell still has to draw the field.

Everything else moves files along lines the plugin architecture already drew.
