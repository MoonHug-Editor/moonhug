# Install, Build and Run
---

Everything the repo does from a terminal goes through `tools/mh`, one Odin
program. It is a TOOL, not a script: shell scripts need a `.sh` and a `.bat` to
cover every platform and the two drift. Odin is already a hard dependency here,
so one program covers all of them — the same reasoning run configs use
(docs/Plugins.md).

## First run

Install [Odin](https://odin-lang.org/docs/install/) and SDL3
(`brew install sdl3`), then, in a fresh clone:

```sh
odin run tools/mh -- setup
```
```sh
odin run tools/mh -- run
```

`setup` builds the vendored C libraries Odin ships as source. `run` generates
code, compiles the editor and launches it.

## Commands

`odin run tools/mh -- <command>` works anywhere Odin does and needs nothing
else installed. With `make` present, `make <command>` is the same thing —
the Makefile only forwards, it holds no build knowledge of its own.

| command | what it does |
|---------|--------------|
| `setup` | build the vendored libraries (once per Odin installation) |
| `run` | build and launch the editor |
| `debug` | the same with `-debug` |
| `build` | build the editor without launching it |
| `app` | build and run the game (`packages/app`) |
| `test` | run the test suite |
| `prebuild` | run the code generators only |
| `shaders` | recompile the built-in GLSL shaders |
| `mcp` | build and run the MCP stdio shim |
| `clean` | empty `builds/` (`--all` also drops the library cache) |
| `help` | list the commands |

Options: `test --name=pkg.test_name` runs a single test (`make test NAME=...`),
`build --debug` builds without launching, `app --debug` picks the debug run
config, `setup --force` rebuilds vendored libraries that are already built.

Commands run from the repo root whatever directory invoked them. `help` and
`setup` work outside a checkout — `setup` only touches the Odin installation.

## What a build does

`run`, `debug` and `build` are the same chain:

1. **prune** — drop imports of removed package generators. A stale one fails
   the prebuild compile before prebuild can heal the file itself, so it runs as
   its own program first.
2. **prebuild** — run the code generators (docs/PrebuildGenerator.md). Skipping
   this does not error, it silently produces a stale binary.
3. **shaders** — only when `glslc` and `spirv-cross` are both on PATH, and
   only for shaders whose source is newer than their compiled output.
4. **compile** — `odin build moonhug/editor`, output `builds/MoonHug`.

The editor is built and then run as a child process rather than with
`odin run`, which would keep the ~1GB compiler resident for the whole life of
the editor just to wait on it.

## Dependencies

- **Odin** and **SDL3** (`brew install sdl3`) — the only things you install by
  hand.
- **Vendored C libraries**, built by `setup`: stb (image decoding), cgltf
  (glTF mesh import), box2d (physics2d package, needs cmake — a WASM warning is
  harmless), box3d (physics3d package, clang only). Odin ships these as source
  and expects them built once per installation. `setup` skips ones already
  built, so it is safe to re-run.
- **glslc + spirv-cross** (`brew install shaderc spirv-cross`) — OPTIONAL.
  Compiled shaders are committed, so this is needed only to CHANGE a shader.
  Builds skip the step when it is absent.

## Shaders

`mh shaders` compiles the built-in GLSL to what SDL_GPU consumes: SPIR-V
(Vulkan) via glslc, MSL (Metal) via spirv-cross. DXIL is added when Windows
rendering support lands. Output under `compiled/` is committed.

Builds compile only shaders whose `.glsl` is newer than both of its outputs, so
an unchanged shader costs nothing. `mh shaders` always recompiles all of them.
The check compares a shader against its own source only — if these ever gain
`#include`s, it needs to learn about them.

The `.glsl` ASSET importer runs the same two tools with different flags
(`engine_editor/asset_pipeline/importer_shader.odin` adds `--reflect` for
binding indices). They stay separate: same tools, different output contracts.

## Derived data

`builds/` is build output and `moonhug/library/` is the derived-data cache
(README "library"). Both are gitignored and rebuild on the next run. `clean`
empties the first, `clean --all` both.

## MCP

`.mcp.json` spawns the stdio shim through `mh mcp` (docs/McpBridge.md). Build
diagnostics go to stderr so stdout stays a clean JSON-RPC stream.

## Adding a command

A command is one entry in `COMMANDS` in `tools/mh/mh.odin` and one procedure.
Set `in_repo` when it touches repo files. Add the matching one-line target to
the `Makefile` — make has no usable catch-all rule (`make test foo` would
invoke the tool twice with reversed arguments), so the two lists are explicit.
