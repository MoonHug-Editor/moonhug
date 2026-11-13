---
title: "Install, Build and Run"
description: "How to install Odin and SDL3, set up a fresh clone, and build, run and test everything with make"
weight: 1
tags: ["build", "testing", "contributing"]
path: general
---

Everything the repo does from a terminal is a `make` command run from the repo root, such as `make setup` or `make run`.

## First run

Install [Odin](https://odin-lang.org/docs/install/) and SDL3 (`brew install sdl3`), then, in a fresh clone:

```sh
make setup
```
```sh
make run
```

`setup` repairs the plugin links in `moonhug/packages/` when a clone produced plain files or dangling links instead (docs/core/Plugins.md, Folder structure), then builds the vendored C libraries Odin ships as source. `run` generates code, compiles the editor and launches it.

On Windows, creating the links needs Developer Mode (Settings, For developers) or an elevated shell. `setup` says so when a link stays broken. Rerun it after enabling.

## Relaunch

The toolbar's rightmost button, past the separator after the run configs, rebuilds and restarts the editor the way it was started. `make run` and `make debug` launch the editor with `MH_LAUNCH=<mode>`, and Relaunch runs the same mode through `tools/mh` again, so a `debug` editor comes back as a `debug` editor. `File/Relaunch` is the same action.

The editor keeps running while the build goes. On success `tools/mh` writes `builds/relaunch_ready`, the editor sees it, quits through the normal path with its settings saved, and `tools/mh` launches the new binary once the old one is gone. A failed build writes no marker: the editor stays up and the compiler output is in the terminal the build runs in.

An editor started as a bare binary has no `MH_LAUNCH`. Relaunch then picks the mode matching the binary's own build, `debug` for a `-debug` build and `run` otherwise, so it still rebuilds and runs the same way. The tooltip shows the exact command it runs. `odin` has to be on the editor's PATH.

## Commands

`make <command>` runs the repo's build tool, `tools/mh`, with that command. It is the same as `odin run tools/mh -- <command>`, except that make compiles `tools/mh` once into `builds/tools/mh` and reuses the binary, where `odin run` compiles it on every call (about 0.5 s). The Makefile only forwards, it holds no build knowledge of its own.

| command | what it does |
|---------|--------------|
| `make setup` | build the vendored libraries (once per Odin installation) |
| `make run` | build and launch the editor |
| `make debug` | the same with `-debug` |
| `make build` | build the editor without launching it |
| `make check-noplugins` | build the editor with the packages folder ignored (`prebuild --no-packages`, nothing moved on disk), run it for a few seconds and close it, one row per stage, PASS or FAIL with the failed stage's output |
| `make play` | run a package's run configuration, the editor's Play button from the terminal (`make play PKG=app:run`, `make play` alone when one package ships them) |
| `make test` | run the test suite. A test whose optional tool is missing, such as CoACD before `setup` built it, skips, and `test` lists it under the summary, which counts it as passed |
| `make test-asan` | the same under AddressSanitizer: a read or write of freed heap memory or past an allocation's end aborts the run with the stacks of the access, the free and the allocation. About four times slower, so it is for after allocator, pool, cache or lifetime changes and before a batch of commits, not after every edit. Leak detection is off (macOS on arm64 has none) and the temp allocator is invisible to it |
| `make scenarios` | run the editor scenarios: tests that start the real editor with a hidden window on a project of their own and drive it through the MCP bridge (see [Scenarios](../core/Scenarios.md)) |
| `make prebuild` | run the code generators only |
| `make deps` | gather plugin dependencies into each `mh_plugin.json` |
| `make shaders` | recompile the built-in GLSL shaders |
| `make docs` | build the documentation site into `builds/docs` (see [Documentation](Documentation.md)) |
| `make mcp` | build and run the MCP stdio shim |
| `make clean` | empty `builds/` |
| `make distclean` | empty `builds/` and drop the library cache |
| `make help` | list the commands |

Options:

- `make test NAME=pkg.test_name` runs a single test, and `make test-asan NAME=...` the same under AddressSanitizer.
- `make scenarios NAME=<test>` runs one scenario, and `SHOW=1` puts the editor's window on screen.
- `make build DEBUG=1` builds the editor with `-debug`, and `make build NOPLUGINS=1` proves the shell builds with no plugin installed.
- `make play PKG=<pkg>:<config> FLAGS=--dev|--run-only|--build-only` are the Play button's modifier keys Alt, Shift and Alt+Shift.
- `make setup FORCE=1` rebuilds vendored libraries that are already built.
- `make deps NAME=<plugin>` gathers one plugin's dependencies.
- `make docs OPEN=1` serves the site with search and opens the browser.

### Tool binaries are cached in `builds/tools/`

- Odin has no build cache, so compiling a tool on every call would cost about 0.5 s each.
- `tools/mh` builds prebuild, the generator pruner and the dependency gatherer once and rebuilds one when a source file is newer than its binary. Prebuild's sources include every installed package's `gen/`.
- `make clean` empties `builds/`. The next command rebuilds the tools.

## What a build does

`make run`, `make debug` and `make build` are the same chain:

1. **prune**: drop imports of removed package generators. A stale one fails the prebuild compile before prebuild can heal the file itself, so it runs as its own program first.
2. **prebuild**: run the code generators (docs/core/PrebuildGenerator.md). Skipping this does not error, it silently produces a stale binary.
3. **shaders**: only when `glslc` and `spirv-cross` are both on PATH, and only for shaders whose source is newer than their compiled output.
4. **compile**: `odin build moonhug/editor`, output `builds/MoonHug`.

The editor is built and then run as a child process rather than with `odin run`, which would keep the ~1GB compiler resident for the whole life of the editor just to wait on it.

## Dependencies

- **Odin** and **SDL3** (`brew install sdl3`): the only things you install by hand.
- **Vendored C libraries**, built by `make setup`: stb (image decoding), cgltf (glTF mesh import), box2d (physics2d package, needs cmake, a WASM warning is harmless), box3d (physics3d package, clang only). Odin ships these as source and expects them built once per installation. `setup` skips ones already built, so it is safe to re-run.
- **CoACD** (MIT, the git submodule `plugins/physics3d/external/CoACD`), built by `make setup` into `plugins/physics3d/external/bin` with cmake: the command line tool the editor runs for the convex decompositions of models. The first build downloads its dependencies (OpenVDB, TBB, Boost, zlib, spdlog) into `builds/coacd`, about 1 GB, and takes a few minutes. The editor builds and runs without it, and a game never needs it.
- **glslc + spirv-cross** (`brew install shaderc spirv-cross`): OPTIONAL. Compiled shaders are committed, so this is needed only to CHANGE a shader. Builds skip the step when it is absent.
- **Hugo 0.166 or newer** (`brew install hugo`): OPTIONAL, used only by `make docs`, which builds the documentation site into `builds/docs` for reading from the file system. The theme is a git submodule, so a fresh clone needs `git submodule update --init`.

## Shaders

`make shaders` compiles the built-in GLSL to what SDL_GPU consumes: SPIR-V (Vulkan) via glslc, MSL (Metal) via spirv-cross. DXIL is added when Windows rendering support lands. Output under `compiled/` is committed.

Builds compile only shaders whose `.glsl` is newer than both of its outputs, so an unchanged shader costs nothing. `make shaders` always recompiles all of them. The check compares a shader against its own source only. If these ever gain `#include`s, it needs to learn about them.

The `.glsl` ASSET importer runs the same two tools with different flags (`plugins/engine/editor/importers/importer_shader.odin` adds `--reflect` for binding indices). They stay separate: same tools, different output contracts.

## Derived data

`builds/` is build output and `moonhug/library/` is the derived-data cache (README "library"). Both are gitignored and rebuild on the next run. `make clean` empties the first, `make distclean` both.

## MCP

`.mcp.json` spawns the stdio shim through the `mcp` command of `tools/mh` (docs/core/McpBridge.md). Build diagnostics go to stderr so stdout stays a clean JSON-RPC stream.

## Adding a command

A command is one entry in `COMMANDS` in `tools/mh/mh.odin` and one procedure. Set `in_repo` when it touches repo files. Add the matching one-line target to the `Makefile`, with a variable for each option: make has no usable catch-all rule (`make test foo` would invoke the tool twice with reversed arguments), so the two lists are explicit.
