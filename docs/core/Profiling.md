---
title: "Profiling"
description: "CPU profiling with Tracy: the three build modes, the marks a package places, how to connect the viewer and capture from the command line"
weight: 200
tags: ["profiling", "performance"]
path: general/architecture
---

MoonHug profiles with [Tracy](https://github.com/wolfpld/tracy). The program holds a small client that sends events to a separate viewer over a local socket. The viewer shows a timeline per thread, cut into frames.

## Build modes

The build picks the mode. `make build`, `make run` and `make debug` all take `PROF`.

```bash
make build PROF=zones
```

| Mode | What is recorded | Cost on the UI demo scene |
| --- | --- | --- |
| `none` | Nothing. The marks are empty procs and the client is not linked. The default. | 6.0 ms a frame |
| `zones` | The marks placed in code. | 5.9 ms a frame, the same within noise |
| `all` | As `zones`, and every proc of the repository is a zone. | 11.9 ms a frame with no viewer, about 18 ms with one |

- Use `zones` for numbers to trust and for daily work.
- Use `all` for a short capture when it is not known where the time goes. It marks very small procs, so their own times are inflated and the trace grows by about 9 MB a second.
- A profiling build records nothing until a viewer connects.
- The client listens on this machine only, on port 8086.
- The Relaunch button of the editor builds in the `none` mode.

## Setup

- The client source is the submodule `moonhug/external/tracy`. `git submodule update --init moonhug/external/tracy` fetches it.
- The first profiling build compiles the client into `builds/tracy/libtracy.a` with `moonhug/libs/prof/build_tracy.sh`. It needs a C++ compiler.
- The viewer and the client are the same Tracy release. `brew install tracy` installs the viewer and the command line tools of the release the submodule is pinned to.

## Marks

A package that places a mark imports `moonhug:libs/prof`. No package has to.

```odin
import "moonhug:libs/prof"

collect :: proc() {
	prof.zone() // this proc, until it returns
	{
		prof.zone("sort quads") // a named scope
		sort()
	}
	prof.plot("quads", f64(count))
}
```

| Proc | Use |
| --- | --- |
| `zone(name)` | A zone that ends with the scope it is called in. With no name it shows as the calling proc. |
| `zone_begin(name)`, `zone_end(z)` | A zone over statements that do not form a scope. |
| `frame_mark()` | The end of a frame. The editor calls it once a frame. |
| `plot(name, value)` | One point of a graph under the timeline. `name` is a literal. |
| `message(text)` | A line on the timeline. |
| `thread_name(name)` | Names the calling thread. `name` is a literal. |
| `connected()` | True while a viewer is connected. |

A zone costs tens of nanoseconds while a viewer is connected and one check when none is. Keep zones out of loops that run thousands of times a frame.

## The all mode

- The compiler calls a proc of `libs/prof` at the start and at the end of every proc (`prof_all.odin`).
- Procs of Odin's own packages are dropped.
- `@(no_instrumentation)` on a proc keeps it out. Use it on a tiny proc that floods the trace.
- A zone placed by hand with no name is skipped, since its proc is a zone already.

## Viewing

1. Start the editor from a profiling build.
2. Start the viewer with `tracy` and connect to `127.0.0.1`.

From the command line, with the editor running:

```bash
tracy-capture -o trace.tracy -a 127.0.0.1 -s 10
```

```bash
tracy-csvexport trace.tracy
```

- `tracy-capture` records for the given number of seconds. Start it after the editor: it does not wait for a program that is not running yet.
- `tracy-csvexport` prints one row per zone with its call count and its mean, minimum and maximum time.
- `tracy trace.tracy` opens a saved trace in the viewer.

## Limits

- On macOS Tracy takes no samples, so code with no zone does not show. The `all` mode and the `sample` tool cover that.
- GPU time is not recorded.
