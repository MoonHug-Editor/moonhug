# Simulate (play in the editor)

Run the open scene inside the editor, then roll it back. Everything stays
inspectable while it runs: the hierarchy updates, the inspector shows live
values, gizmos keep drawing, selection keeps working.

**Toolbar:** Simulate · Pause · Step, centered, with the sim-host dropdown. The
Play button and its run-config dropdown are pinned to the right — a different job
(compile and launch), so a different place.
**Shortcuts:** `Cmd/Ctrl+P` toggles Simulate, `Cmd/Ctrl+Shift+P` pauses.

## Controls

All three buttons are always visible and always enabled, and the cluster never
changes width — a control never moves out from under the cursor. Unity does the
same, because pressing Pause or Step while stopped is a valid way to *enter* a
run.

| Button | Stopped | Running | Paused |
| --- | --- | --- | --- |
| **Simulate** | starts | stops and restores | stops and restores |
| **Pause** | starts paused, on frame zero | pauses | resumes |
| **Step** | starts paused, then one frame | pauses, then one frame | one frame |

Simulate becomes Stop while a run is active, the way Unity's Play button does.
Pause shows a resume icon while held.

**All three buttons turn orange while a simulation is active** — including when
paused, since the scene is still in a simulated state that Stop will revert. The
accent marks the editor's state, not which button is toggled, and the rest of the
toolbar stays theme-neutral. Mistaking a running sim for a stopped editor is the
expensive confusion, because Stop throws away everything the run touched.

A **step** advances exactly one fixed tick and one frame tick, ignoring the
frame-time accumulator — a step is a unit of simulation, not "however long you
spent reading the inspector". A normal run uses the real accumulator, so gameplay
speed matches standalone.

## Simulate vs Play

Two separate buttons, two different jobs.

| | Simulate | Play |
| --- | --- | --- |
| Where the game runs | in the editor process | a separate process |
| Compiles first | no | yes (the run config) |
| Inspectable while running | yes | no |
| Proves the game runs standalone | no | yes |
| Start cost | instant | seconds |

Simulate is for watching and poking at gameplay. Play is the shipping truth: it
compiles the run config, launches the game on its own, and hands it the current
scene state — so it is the one that catches anything working only because the
editor set it up.

## What Stop restores

Stop returns the scene to its state **at the moment Simulate started** — not to
the last save. Unsaved edits made before Simulate come back intact, so Simulate
never forces a save first.

Restored:
- every object's fields and components
- objects the game destroyed during the run
- prefab instances and their overrides
- the selection you had before Simulate

Removed:
- objects the game spawned during the run

## What Stop does NOT restore

**Assets.** The snapshot covers scene objects only. If gameplay changes a
material, a texture, or a settings asset, that change stays after Stop. The
guarantee is "your scene is safe", not "nothing changed".

This matches Unity, and is deliberate rather than a shortfall. Assets live on
disk and are shared by every scene that references them, so they are not part of
any one scene's state. Mutating a material at runtime is also legitimate
gameplay, so refusing the write would break real games. Git is the restore path
for an asset a run changed — the same answer Unity gives.

**Undo history from the run.** Edits made while simulating are dropped on Stop,
along with anything the run recorded. Undo cannot step back into a world that
Stop has already replaced. Undo history from before Simulate survives, as do
asset edits.

## Why it is safe

The snapshot is **the same bytes a save writes**, held in memory instead of
written to disk. Capture goes through the save path (`scene_serialize`), restore
goes through the load path (`scene_load_single_bytes`).

So "can Simulate revert correctly?" is the same question as "can the editor save
and load a scene?" — which every save, every scene test, and
`tests/resave_scenes` already exercise. There is no separate capture format that
could quietly fall behind when a field is added.

Restore reuses the ordinary scene load, which means per-object teardown runs the
same code path a manual delete does: `transform_destroy` fires each component's
`on_destroy_*`, so subsystem state (box2d bodies, audio voices, animation
runners) is released. Nothing about stopping a simulation is special-cased.
`physics2d/tests` covers this for physics.

Restore is **scoped to the simulated scene** (`scene_reload_in_place_bytes`).
Additively loaded scenes are untouched, and the restored scene keeps its slot and
its active-scene status, so the editor carries on editing what it was editing.

It is not atomic: once the old contents are dropped they are gone, so a snapshot
that fails to load leaves the scene unrestored rather than reverted. That is
reported as an error telling you to reopen the scene.

## Identity across the boundary

Handles do not survive. A handle is a pool slot plus a generation, and restore
re-creates every object, so any handle held across Stop would dangle.

Selection is therefore captured as **local ids** — the same stable ids the scene
file stores. On Stop the selection is cleared first (while its handles are still
valid, so the inspector and gizmos let go cleanly), the scene is restored, then
the ids are resolved back to fresh handles. Objects the game destroyed simply do
not resolve, and are dropped from the selection.

## Ticking

Simulate calls the selected sim host's generated dispatchers, reached through the
generated table as proc pointers:

```
fixed ticks (0..k this frame, accumulator-driven)  →  __fixed_update
per-frame tick                                    →  __update
```

Same procs, same order as that game's own loop (see [FixedTick.md](FixedTick.md)),
so a component behaves identically in Simulate and standalone. The editor has no
dispatcher of its own to drift out of sync — `@(update)` and
`@(fixed_update)` subscribers are picked up automatically, including those from
plugins.

## Which game gets ticked (the sim host)

A **sim host** is a runnable package: one whose root declares `main` — a game. The
toolbar's Sim Host dropdown, right of the Simulate controls, chooses which
host's update code Simulate runs.

The list is generated, not configured. Prebuild emits one row per runnable
package into `editor/sim_hosts_generated.odin`, each carrying that host's
`__update` / `__fixed_update`. Install a second game and it appears; there is
nothing to register.

Most repos have exactly one sim host. The dropdown is then **disabled but still
visible**, reading out that game's name — so "which game am I simulating?" always
has a visible answer, and the toolbar never changes shape when a second game
arrives. The choice persists in `editor_settings.sim_host`, stored by name so it
survives hosts being added or removed.

Why this needs choosing at all: every generated dispatcher is emitted *per host*
under a fixed name, which is unambiguous inside a game binary — there is only one
host in it. The editor is not a host and links all of them, so with two games
installed both `app.__update` and `game2.__update` exist. Without a table the
editor could only hardcode one, and would silently tick the wrong game.

Changing host while a simulation runs stops it first, since ticking a scene with
another game's update set is not a meaningful state.

Pause stops the ticking without leaving the simulation, so views keep drawing
and the inspector keeps working on a frozen world. Step then advances that frozen
world one tick at a time.

## Limits

- **One scene.** Simulate captures and restores the ACTIVE scene. Additively
  loaded scenes keep ticking (they share the world) but are not captured, so
  changes gameplay makes to them are not reverted by Stop.
- **Assets are not restored** — by design, as Unity does (see above).

## Asking "is gameplay running?" from component code

```odin
engine.application_is_editor()   // editor binary? fixed per process, Unity's Application.isEditor
engine.application_is_playing()  // gameplay advancing? true in the app, and in the editor while simulating
```

`application_is_playing()` is the one component code wants. It stays true while
paused - Unity's model, where a paused play mode still reports `isPlaying` and
paused is a separate condition. Ask `sim_state()` if you need the distinction.

These two are the whole vocabulary - there is no other mode flag. Editor-only
work (nested-prefab resolve) gates on `application_is_editor()`, so it keeps
running during Simulate. Undo gates on `application_is_playing()`, so it is
unavailable for the whole simulation, paused included - everything a run touches
is discarded on Stop anyway.

## Play-mode phases

Simulate fires four phases, mirroring Unity's `PlayModeStateChange`:

| Phase | When |
| --- | --- |
| `ExitingEditMode` | Simulate pressed, after the snapshot is captured, before the state flips |
| `EnteredPlayMode` | simulation live |
| `ExitingPlayMode` | Stop pressed, while the simulated world is still intact |
| `EnteredEditMode` | after the scene is restored |

```odin
@(phase={key=engine.Phase.EnteredPlayMode, mode=Editor})
my_setup :: proc() { ... }
```

`ExitingEditMode` fires only once the snapshot exists, so a Simulate that fails
to start never emits an unpaired transition. `ExitingPlayMode` runs before the
scene is touched, so subscribers can read the simulated world. Pause fires
nothing - it is not a mode change.

Subscribers owned by a runnable package run only when that package is the active
sim host.

## Code layout

```
editor/simulate/          state machine: start/stop/pause/step, host selection
editor/simulate_view.odin toolbar, shortcuts, and the hooks into editor state
```

The state machine is a subpackage with no imgui or view dependencies, so tests
and tools drive a simulation without the editor root. Editor-owned state
(selection, phase dispatch, the persisted host name) arrives through
`simulate.Hooks`; unset hooks are no-ops, so a driver supplies only what it
needs.
