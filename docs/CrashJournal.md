# Crash Journal

Last words for crashes that can't be reproduced on demand. On SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT — or a panic or failed assert — the process writes `logs/crash_<pid>.log` and then dies normally.

```
=== MoonHug crash ===
reason: SIGSEGV (invalid memory reference)
fault address: 0x8
doing: thumbnail: assets/props/barrel.scene   (optional, see below)
stack:
0   moonhug_editor   0x0000000102c1a954 engine::scene_instantiate_guid + 76
1   moonhug_editor   0x0000000102c0f93c editor::_thumb_render_scene + 52
...
```

`doing:` is optional context. A stack says where it died. A breadcrumb says what it was doing, which turns "it crashed while browsing" into a reproducible report.

## Using it

Lives in its own package, `engine/crash_journal` — no engine state, pure infrastructure. Nothing to enable, the editor installs it before anything that can fault. After a crash, read `moonhug/logs/crash_<pid>.log` (the editor chdirs into `moonhug/`, so the file lands beside the project). `logs/` is gitignored.

Breadcrumbs are opt-in and nothing uses them by default — the journal is complete without one. Add one only when a real crash turns out to be ambiguous from its stack alone:

```odin
crash_journal.breadcrumb(fmt.tprintf("thumbnail: %s", path))
defer crash_journal.breadcrumb_clear()
```

It is last-activity, not a trail — each call replaces the previous one.

Verify the whole path end to end with `moonhug_editor --crash-test`, which faults deliberately and writes a real journal.

## Why it is built this way

Everything on the crash path is async-signal-safe, because the heap may already be corrupt when the handler runs:

- **fixed static storage, zero allocation** — the buffers, the breadcrumb and the output path are all preallocated at init
- **an alternate signal stack** (`sigaltstack`) — a stack-overflow SIGSEGV has no room to run a handler on the faulting stack
- **raw `write(2)` and libc `backtrace_symbols_fd`** — `fmt` allocates and `os` buffers, so neither is legal here. `backtrace_symbols_fd` is the malloc-free symbolizer, which is what makes symbolized frames possible inside a handler at all
- **a reentrancy guard** — a fault inside the handler restores `SIG_DFL` and re-raises instead of looping
- **re-raise after writing** — the process still dies the way it would have, so debuggers still break and exit codes still report

**The faulting frame comes from the trap frame, not the walk.** A signal's trap frame breaks the frame-pointer chain, so libc's `backtrace` inside a handler starts at the handler and cannot see the function that faulted. The handler reads the real PC and LR out of the signal's `ucontext` and prepends them, then skips libc's own handler frames.

**Asserts and panics carry a source location instead of a stack.** They arrive through a no-return proc, which establishes no frame pointer to walk — the `at:` line is authoritative in that case.

## Limits

- POSIX only (darwin, linux). Windows would use `SetUnhandledExceptionFilter` — `crash_journal_stub.odin` is the no-op.
- `context.assertion_failure_proc` lives on the context, so it is installed in `main` rather than inside `crash_journal.init` — a hook set inside init would be discarded on return.
- Symbol quality follows the build. Debug builds name Odin procedures precisely, release builds may attribute to the nearest exported symbol.
