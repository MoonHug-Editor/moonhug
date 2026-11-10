---
title: "Scenarios"
description: "Tests that start the real editor on a project of their own, drive it through the MCP bridge and check what it answers and what it saves"
weight: 191
tags: ["testing", "editor", "mcp"]
path: editor
---

A scenario is a test that runs the real editor. It starts the editor on an empty project, drives it through the [MCP bridge](McpBridge.md), and checks what the editor answers and what it writes to disk. Scenarios cover what a unit test cannot reach, because a unit test has no imgui and no restart: which windows are open, what a window saves, what Reopen Closed brings back, what a quit writes.

```
make scenarios                                    # every scenario
make scenarios NAME=lock_comes_back_with_its_window   # one scenario
make scenarios SHOW=1                             # with the editor's window on screen
```

Scenarios are `@(test)` procs in the package `moonhug/scenarios`. `mh scenarios` builds the editor, then runs that package with `odin test`, so the output, the name filter and the memory tracking are the test suite's.

## How a run works

- A scenario calls `begin(t)` first. It gets a new project in `builds/scenarios/<test name>`, with empty `assets` and `ProjectSettings` folders. What the last run left there is removed first. The project stays after the run, with the editor's output in `run.log`, and a failed scenario prints its path.
- The editor starts with `--project=<that folder>` and `--hidden`, which keeps its window off the screen. It renders and answers as usual. `--show` leaves the flag out.
- The runner reads the bridge file the editor writes in the project and talks to that editor only, so an editor you have open on your own project is not touched.
- The editor answers one bridge call per frame. A call is also a frame, and `frames(r, n)` waits that way. A scenario never sleeps.
- `editor_quit` quits through File/Quit, as a person does, so the editor saves its settings. `editor_restart` quits and starts again on the same project.
- `begin` registers the end of the run with the test (`testing.cleanup`): an editor the scenario left running is killed, whatever the scenario did.
- An editor that is lost (it crashed, a call got no answer in 30 seconds) ends the scenario at once (`testing.fail_now`). A scenario that takes longer than 3 minutes fails.
- The package imports only the bridge's wire protocol (`editor/mcp`), so it builds without the editor's packages.

## Writing a scenario

A scenario is a test in `moonhug/scenarios`:

```odin
// A closed window comes back from Reopen Closed under its key, with its state.
@(test)
reopen_closed_brings_a_window_back :: proc(t: ^testing.T) {
    r := begin(t)
    editor_start(r)
    copy := window_open(r, "Game", another = true)
    window_close(r, copy)
    testing.expectf(t, as_bool(at(window_state(r, copy), "can_reopen")), "the closed copy can come back")

    call(r, "run_command", `{"command":"Window/Reopen Closed"}`)
    frames(r, 2)
    testing.expectf(t, window_is_open(r, copy), "Reopen Closed brings the copy back under its key")
    editor_quit(r)
}
```

What the runner gives (`moonhug/scenarios/runner.odin`):

- **The run**: `begin(t)` returns the `Run` every helper takes.
- **The editor**: `editor_start`, `editor_quit`, `editor_restart`, `frames`.
- **Bridge calls**: `call(r, tool, params)` returns the tool's result, and a tool error is a failed check. `call_raw` gives the error back, for a call that is meant to be refused. `params` is a JSON object as text.
- **Results**: `at(value, "key", 0, "key")` steps into objects and arrays, and `as_string`, `as_bool`, `as_int`, `as_f64` and `has_string` read what it finds. A missing step gives nil, which reads as the zero value.
- **The project**: `project_write` writes a file, before `editor_start` when the editor should find it at startup. `project_json` reads a JSON file the editor saved. `project_path` gives a file's absolute path.
- **Windows**: `window_open`, `window_close`, `window_is_open` and `window_state`, over the bridge's registry tools.
- **Selection**: `select_asset`.

Checks are the testing package's: `testing.expectf(t, ok, format, args)`.

A scenario drives the editor through bridge tools. When it needs to do or read something no tool covers, the tool is added to the bridge (`@(mcp_tool)`), where an agent gets it too.

## Limits

- A scenario costs one editor start, about a second, and another for each restart. They are a target of their own, not part of `make test`.
- The scenarios run one after another.
- A scenario sees what the bridge reports. A picture that looks wrong passes unless a tool reads the value behind it.
