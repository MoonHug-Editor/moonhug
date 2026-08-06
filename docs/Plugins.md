# Plugins (Packages)

Plugin is a package folder in `moonhug/packages/`.
- Its code is a plain Odin package reached as `moonhug:packages/<name>`.
- Its `assets/` folder is scanned by the asset db — nothing else in the package is.
- Samples install as further packages.

The attribute system (`@component`, `@update`, `@phase`, `@menu_item`,
`@property_drawer`, …) is the plugin API — packages use the exact same markers
app code already uses.

## app plugin
**The app is a plugin too** (`packages/app`) — an ordinary package with a `main :: proc()`, a and game loop.

**Runnable packages** Any package root declaring `main` is "runnable"
and receives its OWN generated dispatcher set (`__update`, `phase_run`,
`register_type_guids`, `register_packages`).

Each dispatcher is emitted per runnable package under a fixed name, which is
unambiguous inside a game binary — it contains one host. The EDITOR links all of
them, so it also gets a table naming them: `editor/sim_hosts_generated.odin`, one row
per runnable package with its `__update` / `__fixed_update`. That is how the
editor's Simulate (docs/Simulate.md) knows which game to tick, and what its Sim
Host dropdown lists.

## Folder structure

```
moonhug/packages/
  physics2d/                ← runtime package:  import "moonhug:packages/physics2d"
    physics.odin
    component_Rigidbody2D.odin
    components_ext_generated.odin  ← emitted by prebuild: component registration
    editor/                 ← OPTIONAL editor-only package:  import "moonhug:packages/physics2d/editor"
      gizmos.odin
    assets/                 ← the ONLY subtree the asset db scans. Visible in project view (auto-created)
      debug.mat
      debug.mat.meta        ← metas authored & committed WITH the package
    samples/                ← OPTIONAL samples, inert until installed as packages
      platformer/
        *.odin
        assets/
    tests/                  ← OPTIONAL test suite: `package physics2d_tests`
    run_configs/            ← OPTIONAL runnable-package programs (see Run configurations)
      run.odin
      run_debug.odin
```

- **Package root = the runtime Odin package.** Compiled into BOTH binaries
  (editor imports app). Folder name is the package identity and the declared
  `package` name.
- **`editor/`** — editor-only code (gizmos, custom inspectors, menu items).
  Compiled into the editor binary only, never the app. Declares
  `package <name>_editor` — every plugin's folder is named `editor/`, so the
  declaration carries uniqueness (prebuild lints it).
- **`assets/`** — live content: mounted, browsable, editable, referenced by
  guid like any project asset. Content outside `assets/` doesn't exist to the
  editor — the rule is structural, no filters needed. The editor ENSURES this
  folder exists for every installed package (creates it on refresh if
  missing), so package roots always resolve — no corner cases.
- **`samples/`** — one subfolder per sample, each shaped like a plugin.
  Inert by construction: the asset db only reads `assets/`, and
  prebuild only scans its explicit targets (package root and `editor/`), so
  nothing ever looks inside `samples/` until a sample is installed.
- **`tests/`** — the package's test suite (`package <name>_tests`), sharing
  the bootstrap in `moonhug/tests/common`. Prebuild imports every installed
  suite into `moonhug/tests/packages_tests_generated.odin`, so run_tests.sh
  covers everything in one `odin test -all-packages` run. Tests ship with the
  package and die with it on uninstall — the central suite only reaches
  `moonhug:packages/` through that generated file.
- **`run_configs/`** — Odin programs that build+run the package as a program (see Run configurations)
- Other subfolders are just folders with no special meaning.

## Run configurations

A package that can run as a program (the `app` package, a future headless
server, an engine sample) ships configurations in `run_configs/`:

- One `.odin` file per configuration; the FILENAME is the config's name — no
  metadata inside, no manifest. Each file declares its own `package` name
  (matching the filename by convention) and a `main`, so several configs
  coexist in the folder: the editor compiles each with `-file`, one at a time.
- A config is an Odin PROGRAM, not a script. `moonhug:editor/runconfig` — an
  editor-only subpackage, like `moonhug:editor/undo` — supplies the shared odin
  flags, the platform executable suffix, output-directory creation, and
  argument forwarding, so the common case is one call:

  ```odin
  package run_debug

  import rc "moonhug:editor/runconfig"

  main :: proc() {
      rc.build_and_run({
          package_path = "moonhug/packages/app",
          out          = "builds/app_debug",
          flags        = {"-debug"},
      })
  }
  ```

- Configs run from the REPO ROOT and receive the editor's args — the
  live-scene snapshot path when launched via Play. `build_and_run` forwards
  them to the game and exits with the game's exit code. The same config runs
  from a terminal:
  `odin run moonhug/packages/app/run_configs/run.odin -file -collection:moonhug=moonhug`
- The editor's toolbar Play is a split button: the play half compiles and runs
  the selected configuration, the dropdown half lists every
  `packages/*/run_configs/*.odin` as `<package>: <name>`. The selection
  persists in `ProjectSettings/editor_settings.json`; with no selection the
  editor prefers a `run_debug` config (call-stack capture for console logs).
- Configs are ALWAYS recompiled before running, into
  `builds/run_config_<package>_<name>`. No cache, so nothing goes stale. A
  config that fails to compile never launches, and its diagnostics reach the
  console the same way build output does.

## Install model

Presence in `packages/` = installed. Management is manual and mechanism-free:
copy a folder in, delete it to uninstall, use a symlink or git submodule if
you personally prefer — the editor doesn't know or care, it only ever sees a
directory. Packages committed with the repo are shared with the team
automatically (Unity's *embedded packages* model).

Install/remove changes what gets compiled, so it takes a prebuild + rebuild
(run.sh). Static compilation is deliberate: Odin has no useful dylib story
(no stable ABI, `typeid` identity breaks across boundaries), and static keeps
plugin code debuggable and optimizable like first-party code.

## Code
Prebuild scans `packages/*` and `packages/*/editor` (the app included — it
carries no special scan status), then generates:

- `components_ext_generated.odin` inside each package — the same runtime
  component registration app components use (`register_<name>_components()`,
  ext pools, guid blob records) plus typed pool accessors and `get_comp`.
- `@update` ticks and `@typ_guid` types are baked package-qualified into the
  existing central dispatchers (`__update`, `register_type_guids`), fully
  interleaved with app entries by order. `@menu_item` in `editor/` packages
  lands in the editor's menu registration the same way. `@phase` subscribers
  work from packages too (editor-side ones must declare `mode=Editor`) — the
  `Phase` enum plus a subscriber table live in
  `engine/phases_generated.odin`. In the editor dispatcher
  (`phase_editor_run`), entries owned by a runnable package run only when that
  package is the active sim host — subscribers from several hosts interleave by
  `order`, and the guard skips the inactive ones.
- The import lines, so presence = compiled + registered in both binaries:

  ```
  moonhug/packages/app/packages_generated.odin   imports + register_packages()
  moonhug/editor/packages_generated.odin         import _ "moonhug:packages/<name>/editor"
  ```

  `register_packages()` is called from `app_init`/`editor_init` right after
  `register_app_components()`.

An editor package may import its own runtime package, `engine`,
`engine_editor`, imgui and the editor's subpackages (`menu`, `inspector`,
`undo`, `window`). Never the editor root — that's a cycle, the root imports
plugin editor packages. Editor integration goes through attributes.

## Editor windows

A plugin declares a dockable editor window with an attribute and opens it by
id, the way Unity's `[MenuItem]` calls `EditorWindow.GetWindow`:

```odin
import wnd "moonhug:editor/window"

@(editor_window={id="physics2d", title="Physics 2D", width=420, height=240})
draw_physics_debug :: proc() {
    // window CONTENT only — Begin/End, the close button and the open flag
    // belong to the host
}

@(menu_item={path="Window/Physics 2D", shortcut=""})
open_physics_debug :: proc() {
    wnd.open("physics2d")
}
```

- `title` defaults to the id. `width`/`height` are the first-shown size,
  applied only while imgui.ini has no entry for the title (`FirstUseEver`) —
  once the user resizes or docks it, imgui.ini wins.
- `open` focuses the window if it is already open. Any code path can call it —
  a button or context menu works as well as a menu item.
- The open list is process-lifetime (reopen from the menu after a restart);
  dock position and size persist in imgui.ini by title.
- Declarations land in `editor/editor_windows_generated.odin`
  (editor_window_gen). `packages/plugin_example/editor` carries a working demo.

## Project settings

A plugin adds a section to the editor's Project Settings window
(Edit ▸ Project Settings…) by marking a package-level struct var — the data IS
the registration:

```odin
@(project_settings={name="Physics 2D"})
physics2d_settings := Physics2D_Settings{gravity = GRAVITY_DEFAULT}

Physics2D_Settings :: struct {
    gravity: [2]f32,
}
```

- The window draws the struct through the inspector, so `decor:` tags and
  @(property_drawer) overrides apply — register a drawer for the settings TYPE
  for a fully custom pane. Edits land in the global undo history.
- Values persist to `ProjectSettings/<slug>.json` ("Physics 2D" →
  `physics_2d.json`) whenever they change while the window is open, and again
  at editor shutdown.
- The OWNING system loads its own file (`engine.project_settings_load`) and
  consumes the var by polling, so an edit — typed, undone or redone — reaches
  the runtime with no editor coupling, and the game binary reads the same
  files. `packages/physics2d/settings.odin` is the shipped example: the fixed
  step syncs the var into the live box2d world.
- Declarations land in `editor/project_settings_generated.odin`
  (project_settings_gen). Built-in tabs use the same attribute — Time
  (`engine.time_settings`, the fixed tick rate) is one.

## Assets

The asset db walks `assets/` plus `packages/<name>/assets` per package.
- Metas are committed with the package, so its guids are the same in every project.
- References are guid-based, so removing a package just leaves unresolved refs (Unity's missing-package behavior).
- Duplicate guids error loudly on refresh.

Each package's `assets/` folder is an **additional root**, the same concept
as the existing Assets root: label = package name, path = the root directory
(`packages/<name>/assets`). Project view shows these roots under a top-level
**Packages** node, one row per installed package — the root directory always
exists because refresh auto-creates a missing `assets/` folder. The Packages
node and its direct children (the package
rows) are special the way the Assets root already is: non-renameable,
non-deletable, no file ops on the rows themselves. Selecting a package —
the left-pane node or the right-pane row — opens the package inspector:
name, content root, asset count, and the Samples section.

## Samples
- `samples/` itself is never scanned by AssetDb, so the originals' guids don't exist until installed.
- Install/Remove happens via the package inspector's Samples section (manual folder ops work too — presence = installed).
- Install = copy `packages/<pkg>/samples/<sample>/` → `packages/<sample>/`, `.meta` files included (sample guids are committed with the package). Or Symlink — a relative link `packages/<sample>` → the sample source, for live-editing sample files.
  - From that moment it's an ordinary package: code compiles, assets mount, user-owned (copy) or source-backed (symlink).
- Remove asks confirmation: a copied install goes to the OS Trash (it may carry user edits), a symlink is just unlinked — the source stays.
- Assets mount immediately on install; code takes a prebuild + rebuild (run.sh), like any package install.
- The package scans follow directory symlinks (prebuild discovery, asset-db package roots, project-view listings), so a linked sample behaves exactly like a copied one.

## Considered Later
- Package Manager window — list packages/samples, install-sample button, "rebuild required" notice.
- Readonly packages — `asset_readonly(path)` predicate + gates at editor write sites.
- Archive/pak mounts — shipping form of package content.
