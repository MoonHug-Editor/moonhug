---
title: "Architecture"
description: "The Editor and the App, the layers they are built from, what each layer owns, and the one rule about imports"
order: 1
tags: ["design", "plugins", "editor", "engine"]
path: general/architecture
---

The libs are the packages that run nothing on their own. Two executables are built on them: the **Editor**, which you edit a project in, and the **App**, the project's own executable. Plugins are what the Editor and the App load, and the engine is one of them: a project uses it or not.

## Vocabulary

| Word | Means | Lives in |
|---|---|---|
| **Libs** | Small packages the Editor and an App build on, each imported on its own and only where it is used: `core` (handles, references, phases, the type registry, settings), `log`, `serialization`, `assets` and `catalog` (the asset database and what an App ships), `gfx` and `input` (the window and the platform), `gizmos`, `crash_journal`. | `moonhug/libs/<name>` |
| **Editor** | The generic editing application: windows, docking, menus, inspector, undo, project view, viewport, Simulate, console. It declares the extension points plugins fill and builds with no plugin installed. | `moonhug/editor` |
| **Plugin** | A package a project installs. It has a runtime part that ships in the App and an optional `editor/` part that is linked only into the Editor. It extends the Editor and the App through attributes. | `plugins/<name>` |
| **Engine** | The plugin that brings scenes, transforms, components, rendering, materials, meshes, the fixed tick and the App's frame loop. Other plugins build on it. | `plugins/engine` |
| **App** | A runnable plugin, one whose root declares `main`, built as its own executable. A game is one kind of app. | `plugins/app`, a project's own package |
| **Prebuild** | The generator that runs before compiling. It reads the attributes in every installed package and writes the glue: dispatchers, registrations, the editor's windows and menus, the reference docs. Plugins ship their own generators in `gen/`. | `moonhug/prebuild` |

A **package** is an Odin package. Plugin, engine and app are roles a package plays. The Editor and the libs are packages too, but they are never plugins: a plugin is something a project can leave out, and the Editor cannot leave out its own shell.

## Layers

```
App      libs ── engine plugin ── other plugins —— the app package
Editor   libs ─┬ engine plugin ── other plugins ── the app package
               │  └ engine/editor/   └ <plugin>/editor/   └ app/editor/  <- */editor packages can import editor
               └ editor
```

Imports go one way, from right to left along a line and up a branch. The Editor runs the same plugin code the App does, and adds each plugin's `editor/` part, which imports its own plugin and the shell. The shell branches off the libs beside the plugins: it imports no plugin, and no runtime part imports the shell or any `editor/` part.

- a libs package imports nothing above it, and little beside it: `core` imports nothing, `gfx` only `input`, `assets` only `core`, `log` and `catalog`
- the editor imports the libs, never a plugin
- a plugin imports the libs, the editor's extension points from its `editor/` part, and the plugins it declares as dependencies
- the app package imports what it uses, like any plugin. The smallest App imports `moonhug:libs/core` and nothing else: no window, no asset database, no engine. The Editor still inspects its structs, opens its windows and runs its config. Odin compiles only what the App references, so an imported package costs what is used of it

The editor reaches a plugin only through what the plugin registered: an attribute the prebuild turned into a call, or a provider the plugin installed at startup. With no engine installed those stay empty and the editor runs without that capability.

## What each side owns

| Editor | Engine plugin |
|---|---|
| windows, docking, views, menus, toolbar | scene view, hierarchy, game view |
| inspector reflection, field rows, undo recording | drawers for the engine's reference and asset types |
| the undo stack, grouping, sessions | undo operations on scenes and prefabs |
| the viewport: camera, navigation, picking, overlay | render collectors that draw meshes, sprites and lights into it |
| project view, asset database, importer registry, thumbnails | importers for meshes, textures, scenes, and the asset types |
| run configs, Simulate controls, Game view focus | building and launching the App, snapshot and restore of the world |
| settings windows, console, dialogs, the MCP transport | MCP tools that read and edit scenes |
| prebuild, attributes, the reference docs | the engine's generators and its docs |

The pattern is the same in every row: the editor owns a mechanism, the plugin owns what runs inside it.

## How a plugin extends the Editor and the App

- **Attributes** on declarations: `@(component)`, `@(update)`, `@(phase)`, `@(editor_window)`, `@(menu_item)`, `@(property_drawer)`, `@(importer)` and the rest. The prebuild collects them and writes the code that calls them. [Attributes](../reference/attributes/_index.md) lists every one with its uses.
- **Providers** for what an attribute cannot express: a struct of procs the editor declares and a plugin fills at startup, such as the viewport's render and pick, or the world Simulate snapshots. A provider that nobody fills is absent, and the editor skips that capability.
- **Phases** for lifecycle: `EngineInit`, `Init`, `SceneLoaded`, `Shutdown` and the editor's own, run in order by generated dispatchers in the Editor and in the App.

[Plugins](Plugins.md) describes the package layout, the manifest and the install model.

## How to check the separation

- `make build NOPLUGINS=1` builds the Editor with every plugin set aside. It has to succeed.
- Tests live with what they test: the libs's in `moonhug/tests`, the editor's in `moonhug/editor/tests`, each plugin's in its `tests/` folder. `mh test` runs them all.
- A hand-written file in `moonhug/editor`, `moonhug/libs` or `moonhug/registration` that imports the engine fails the boundary test.
