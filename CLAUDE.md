# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MoonHug is a generic, Unity-inspired game engine editor, written in [Odin](https://odin-lang.org/). Vertical Slice Experimental stage: frequent API changes, non-implemented features expected. Goals: a highly/easily extensible level editor that lets differently-skilled people combine resources into interactive elements.

## Commands

All commands run from the repo root. Requires the Odin compiler (`odin` on PATH) and the `moonhug=moonhug` collection flag — every build/test/run invocation needs `-collection:moonhug=moonhug`.

```sh
./run.sh            # prebuild (codegen) -> build editor (release) -> exec builds/MoonHug
./run_debug.sh       # same, but -debug build
./run_tests.sh       # odin test moonhug/tests -all-packages -ignore-unknown-attributes -collection:moonhug=moonhug -define:ODIN_TEST_THREADS=1
```

Equivalent manual steps (what the scripts do):

```sh
# 1. Prune imports of removed package generators (must run first; stale imports break prebuild's own compile)
odin run moonhug/prebuild/prune_package_gens

# 2. Prebuild: runs code generators (menu_gen, components_gen, etc.) -> writes *_generated.odin
odin run moonhug/prebuild -collection:moonhug=moonhug

# 3. Build + run editor (build then exec, NOT `odin run` -- keeps the ~1GB compiler process from lingering)
odin build moonhug/editor -ignore-unknown-attributes -collection:moonhug=moonhug -out:builds/MoonHug
./builds/MoonHug

# App/game binary equivalent
odin build moonhug/packages/app -ignore-unknown-attributes -collection:moonhug=moonhug -out:builds/app
```

Tests:

```sh
# Full suite (central tests/ + every installed package's tests/, one run)
odin test moonhug/tests -all-packages -ignore-unknown-attributes -collection:moonhug=moonhug -define:ODIN_TEST_THREADS=1

# Single test or test subset -- format is package.test_name, comma-separated
odin test moonhug/tests -all-packages -ignore-unknown-attributes -collection:moonhug=moonhug -define:ODIN_TEST_NAMES=tests.some_test_name
```

Whenever you add/remove/rename an `@component`, `@phase`, `@menu_item`, or any other attribute-driven declaration, rerun prebuild (step 2 above, or just `./run.sh`) before building — the `*_generated.odin` files are checked in but must be regenerated, and a stale generated file will not error, it will silently not include the new code.

One-time native dependency builds (see README for details): `make -C "$(odin root)/vendor/stb/src"`, `make -C "$(odin root)/vendor/cgltf/src"`, box2d's `build_box2d.sh` (physics2d), box3d's `build.sh` (physics3d, clang only). Optional shader toolchain (`glslc` + `spirv-cross`) recompiles `moonhug/engine/gfx/shaders/compile.sh`'s output; compiled shader blobs are committed, so this is only needed to author new/changed built-in or `.glsl` shaders.

MCP bridge shim (agent access to a running editor instance, registered in `.mcp.json`): `sh run_mcp_shim.sh` — builds `builds/mcp_shim` quietly (stdout must stay a clean JSON-RPC stream) and execs it.

## Architecture

### Package layout and dependency direction

- `moonhug/engine/` — core dependency for both app and editor: components, pools, scenes, asset pipeline, rendering, serialization. No editor knowledge.
- `moonhug/editor/` — top-level package with dependencies on everything; the running level editor.
- `moonhug/engine_editor/` — currently empty (placeholder).
- `moonhug/packages/app/` — the game itself, ordinary Odin package with `main :: proc()`. Must never depend on the editor. **The app is a plugin too**, structured exactly like a package under `packages/`.
- `moonhug/packages/*` — plugins (physics2d, physics3d, audio, tween, node_graph, essentials, plugin_example, prefabs_example). Each is a self-contained Odin package; presence in `packages/` = installed (copy/delete/symlink, no registration step).
- `moonhug/prebuild/` — a separate program, run before anything else compiles. Scans attribute markers across engine/editor/packages and emits `*_generated.odin` files.
- `moonhug/tests/` — central test suite (`package tests`); imports each installed package's `tests/` via a generated file, so `run_tests.sh` covers everything in one invocation.
- `builds/` — build output (gitignored). `library/` — derived-data cache, Unity's `Library` model: entirely safe to delete, rebuilt on next run (import artifacts, thumbnails, editor session state).

Package dependency rule (see [docs/ArchitectureNotes.md](docs/ArchitectureNotes.md)): dependencies point downward; leaf packages import nothing of the game and export one system; parent/glue packages import children and wire them together; dependency cycles are a design error, never patch one with a callback back up the tree.

### Plugin package anatomy (`moonhug/packages/<name>/`)

```
<name>.odin, component_*.odin  root package: moonhug:packages/<name>
editor/                        optional editor-only half: moonhug:packages/<name>/editor, package <name>_editor
assets/                        the ONLY subtree the asset db scans; auto-created; guid-referenced project content
samples/                       inert until installed as their own packages (asset db + prebuild skip this dir)
tests/                         package <name>_tests, imported into the central suite by prebuild
gen/                           optional prebuild generator (package <name>_gen), compiles into the prebuild program, not the binaries
run_configs/                   optional runnable-program configs (one .odin file per config, filename = config name)
```

Full detail in [docs/Plugins.md](docs/Plugins.md).

### The attribute + prebuild codegen system

This is the plugin API and the main mechanism for extending the editor without touching core code. Attributes like `@(component)`, `@(update={order=0})`, `@(fixed_update={order=10})`, `@(phase={key=...})`, `@(menu_item={path="..."})`, `@(property_drawer=...)`, `@(inspector_button={...})`, `@(editor_window={id="..."})`, `@(project_settings={name="..."})`, `@(mcp_tool={...})`, `@(scene_overlay={...})` mark ordinary procs/structs; `moonhug/prebuild` scans the AST once, classifies declarations into plain-data components (`gen_facts`), and per-concern generator modules (`*_gen` packages under `moonhug/prebuild/`) query those components and emit `*_generated.odin` files. See [docs/PrebuildGenerator.md](docs/PrebuildGenerator.md) for the provider/generator pipeline and how to add a new generator module.

Consequence for editing: a new `@component`/`@phase`/etc. declaration does nothing until prebuild reruns and regenerates the relevant `*_generated.odin` — always rerun prebuild after adding or changing attribute-marked declarations, and never hand-edit a `*_generated.odin` file (it is overwritten).

### Data model

- **Component** = plain struct registered with `@(component)`, stored in a fixed-size `Pool(T, N)` per type per `World`. A `Handle` (index + generation + type key) is the durable reference; pointers from `pool_get` are frame-local only — re-resolve through the handle across frames, never cache the pointer. Iterate via `pool_iterator`/`pool_next`, never touch pool internals directly. See [docs/Components.md](docs/Components.md).
- **Transform** owns the scene hierarchy and each object's component list.
- **Scene / SceneFile**: `Scene` is a thin runtime header (root `Ref`, generation counter); actual entity data lives in `World` pools. `SceneFile` is the flat, pointer-free on-disk JSON snapshot (arrays of transforms/components keyed by `Local_ID`). `PPtr` (guid + local_id) is what's serialized; `Handle` is runtime-only and resolved at load time. See [docs/Scenes.md](docs/Scenes.md) and [docs/Concepts.md](docs/Concepts.md).
- **Assets**: filesystem watcher → importer registry (by extension) → `.meta` sidecar (stable guid, dirty-checked via mtime then hash) → compiled artifact written under `library/artifacts/<xx>/<key>.bin`, content-addressed by a hash of every input that shapes the output (source bytes, import settings, importer version, artifact format version). Runtime code never touches paths, only guids. See [docs/AssetPipeline.md](docs/AssetPipeline.md) and the `library/` section of the README.
- **Time enters the tree at the root** — the top-level app/editor loop calls child updates in explicit order; gameplay code never self-schedules via engine callbacks (visual-only events are the exception). Fixed-rate simulation is a single global 60 Hz tick (`engine/fixed_tick.odin`, configurable via Project Settings) with an accumulator and a catch-up cap — see [docs/FixedTick.md](docs/FixedTick.md) for `@(fixed_update={order=..., divisor=...})` vs `@(update={order=...})`, and use the `_fixed` input variants (`input.key_down_fixed`, etc.) inside fixed code so short presses aren't missed between ticks.

### Editor-specific machinery

- **Undo**: edits go through the editor's undo stack; `Property_Target` re-resolves its pointer at apply/commit time rather than dereferencing a raw pointer across frames. See [docs/Undo.md](docs/Undo.md).
- **Simulate** (Play-in-editor without launching a separate process) vs. the toolbar **Play** button (compiles + runs a `run_configs/*.odin` program as its own process, forwarding the live-scene snapshot path). See [docs/Simulate.md](docs/Simulate.md) and the Run configurations section of [docs/Plugins.md](docs/Plugins.md).
- **MCP Bridge** ([docs/McpBridge.md](docs/McpBridge.md)): the running editor exposes a loopback TCP endpoint (`editor/mcp_bridge.odin`, polled once/frame, main-thread only); `moonhug/mcp_shim` is the stdio MCP server (registered in `.mcp.json`) that discovers/authenticates against it and translates JSON-RPC. New tools are declared with `@(mcp_tool={...})` on a proc and picked up by `mcp_tool_gen`. Toggle at Edit ▸ Project Settings ▸ MCP.
- **Crash Journal** ([docs/CrashJournal.md](docs/CrashJournal.md)): signal-safe crash log with symbolized stack, written to `moonhug/logs/crash_<pid>.log`.

### Style

- Naming follows [Odin's convention](https://github.com/odin-lang/examples/wiki/Naming-and-style-convention) except where noted in [docs/StyleGuide.md](docs/StyleGuide.md): Import names snake_case (prefer single word); Types/Enums PascalCase_UnderscoreTolerant; Procedures/locals snake_case; Constants SCREAMING_SNAKE_CASE.
- Non-generic functionality is acceptable in generated code when needed, but should not live in hand-written main code where a generic approach is comparably simple/performant.
- Full docs index lives in the README's Features list and under `docs/`; when a change affects an existing documented feature, update the corresponding `docs/*.md`.

## Versioning

`moonhug/version` and `CHANGELOG.md` are managed by semantic-release (`.github/workflows/release.yml`, triggered on push to `main`) from Conventional Commits — do not hand-edit either file.
