# Plugins (Packages)

Plugin is a package folder in `moonhug/packages/`.
- Its code is a plain Odin package reached through the `packages:` collection.
- Its `assets/` folder is scanned by the asset db — nothing else in the package is.
- Samples install as further packages.

The attribute system (`@component`, `@update`, `@phase`, `@menu_item`,
`@property_drawer`, …) is the plugin API — packages use the exact same markers
app code already uses.

**The app is a package too** (`packages/app`): the game — main loop included —
is an ordinary package with a `main :: proc()`. In Odin `main` is only special
in the package handed to `odin build`, so the same package builds as the game
executable AND imports into the editor like any plugin.

**Runnable packages, 0..N of them.** Any package root declaring `main` is
"runnable" and receives its OWN generated dispatcher set (`__update`,
`phase_run`, `register_type_guids`, `register_packages`): its own subscribers
call unqualified, library packages import through the collection, OTHER
runnable packages are excluded (they're separate programs). The editor and
the tests bootstrap depend on no runnable package — they use the generated
`moonhug/registration` package (all types, all packages), so deleting the
app leaves a fully working editor.

## Folder structure

```
moonhug/packages/
  physics2d/                ← runtime package:  import "packages:physics2d"
    physics.odin
    component_Rigidbody2D.odin
    components_ext_generated.odin  ← emitted by prebuild: component registration
    editor/                 ← OPTIONAL editor-only package:  import "packages:physics2d/editor"
      gizmos.odin
    assets/                 ← the ONLY subtree the asset db scans. Visible in project view (auto-created)
      debug.mat
      debug.mat.meta        ← metas authored & committed WITH the package
    samples/                ← OPTIONAL samples, inert until installed as packages
      platformer/
        *.odin
        assets/
    tests/                  ← OPTIONAL test suite: `package physics2d_tests`
    run_configs/            ← OPTIONAL runnable-package scripts (see Run configurations)
      run.sh
      run_debug.sh
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
  `packages:` through that generated file.
- **`run_configs/`** — shell scripts that build+run the package as a program
  (see Run configurations). Inert to the asset db and the compiler.
- Other subfolders are just folders with no special meaning.

## Run configurations

A package that can run as a program (the `app` package, a future headless
server, an engine sample) ships scripts in `run_configs/`:

- One `.sh` per configuration; the FILENAME is the config's name — no
  metadata inside, no manifest.
- Scripts run from the REPO ROOT and receive the editor's args (`"$@"` —
  the live-scene snapshot path when launched via Play); they build the
  package and `exec` the binary, forwarding the args. The same script works
  from a terminal: `sh moonhug/packages/app/run_configs/run.sh`.
- The editor's toolbar Play is a split button: the play half runs the
  selected configuration, the dropdown half lists every
  `packages/*/run_configs/*.sh` as `<package>: <name>`. The selection
  persists in `ProjectSettings/editor_settings.json`; with no selection the
  editor prefers a `run_debug` config (call-stack capture for console logs).

Build variants (debug/release), extra flags, program args — all just script
content, no schema.

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
  `engine/phases_generated.odin`.
- The import lines, so presence = compiled + registered in both binaries:

  ```
  moonhug/packages/app/packages_generated.odin   imports + register_packages()
  moonhug/editor/packages_generated.odin         import _ "packages:<name>/editor"
  ```

  `register_packages()` is called from `app_init`/`editor_init` right after
  `register_app_components()`.

An editor package may import its own runtime package, `engine`,
`engine_editor`, imgui and the editor's subpackages (`menu`, `inspector`,
`undo`). Never the editor root — that's a cycle, the root imports plugin
editor packages. Editor integration goes through attributes.

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
non-deletable, no file ops on the rows themselves. Selecting a package row
opens a special package inspector.

## Samples
- `samples/` itself is never scanned by AssetDb, so the originals' guids don't exist until installed.
- Install/Remove should happen via package inspector, but also can be done manually.
- Install = copy `packages/<pkg>/samples/<sample>/` → `packages/<sample>/`. Or use symlink/junction to modify sample files.
  - From that moment it's an ordinary package: code compiles, assets mount, user-owned,
- uninstall = delete the folder.

## Later
- Install Samples inspector when selecting packages/package folder
  - should handle all kinds of situations(Add/Remove/Replace, symlinks)

## Considered Later
- Package Manager window — list packages/samples, install-sample button, "rebuild required" notice.
- Readonly packages — `asset_readonly(path)` predicate + gates at editor write sites.
- Archive/pak mounts — shipping form of package content.
