package simulate

// In-editor simulation: tick the open scene in place, then roll it back.
// See docs/core/Simulate.md.
//
// Logic only, with no imgui or view dependency, so tests and tools drive a
// simulation without the editor root. Toolbar: editor/simulate_view.odin.
//
// The world being simulated is a provider (world.odin): the engine captures
// and restores its scenes and runs the fixed ticks.

import "base:runtime"
import core "moonhug:host/core"
import "moonhug:host/log"
import "moonhug:editor/undo"

State :: enum {
    Stopped,
    Running,
    Paused,
}

// One runnable package the editor can tick. Rows come from the generated table
// (moonhug/registration/sim_hosts_generated.odin), which sim_world converts and
// passes to set_hosts.
Host :: struct {
    name:         string,
    path:         string,
    update:       proc(dt: f32),
    fixed_update: proc(dt: f32),
}

// Editor-root state reached through callbacks: selection, phase dispatch and the
// persisted host name live in the root, which this package cannot import. An
// unset hook makes its step a no-op.
Hooks :: struct {
    selection_ids:     proc() -> []core.Local_ID, // ids to restore after Stop
    selection_clear:   proc(),
    selection_add_id:  proc(scene: core.Scene_Ref, id: core.Local_ID),
    phase:             proc(p: Phase),
    host_name_load:    proc() -> string,
    host_name_store:   proc(name: string),
}

// Play-mode transitions (Unity's PlayModeStateChange). The root maps these onto
// engine.Phase values.
Phase :: enum {
    ExitingEditMode,
    EnteredPlayMode,
    ExitingPlayMode,
    EnteredEditMode,
}

_state: State
_hooks: Hooks
_hosts: []Host
_host: int

// The world at Start, as the world provider encoded it, and the scene a Stop
// restores. The scene is remembered by session id, not pointer: a scene
// unloaded during the run frees its struct, and a later scene can be
// allocated at the same address.
_snapshot: []byte
_scene: core.Scene_Ref

// Ids of the objects selected at Start. Handles hold a pool slot + generation and
// restore re-creates every object, so ids are what survives.
// Like every global here it outlives the caller, so it pins the default allocator.
_selection: [dynamic]core.Local_ID

// Set by step, consumed by the next tick: advance one frame, then hold.
_step_pending: bool

install :: proc(hooks: Hooks, hosts: []Host) {
    _hooks = hooks
    set_hosts(hosts)
}

// The table is borrowed, not copied: the caller keeps it alive while it is
// installed. Picks the host the host_name_load hook names, row 0 otherwise.
set_hosts :: proc(hosts: []Host) {
    _hosts = hosts
    _host = 0
    if _hooks.host_name_load == nil do return
    want := _hooks.host_name_load()
    if want == "" do return
    for h, i in _hosts {
        if h.name == want {
            _host = i
            return
        }
    }
}

shutdown :: proc() {
    if _state != .Stopped do stop()
    delete(_selection)
    _selection = nil
}

state :: proc() -> State {
    return _state
}

is_active :: proc() -> bool {
    return _state != .Stopped
}

// The scene captured at Start, or the zero ref when stopped. The hierarchy
// asks so it can keep Unload off the one scene a Stop has to restore.
scene :: proc() -> core.Scene_Ref {
    return _state != .Stopped ? _scene : {}
}

// True while the scene advances. Paused holds the world without leaving.
is_ticking :: proc() -> bool {
    return _state == .Running
}

// Ask to start next frame: editor previews (the sequencer's scrub, the
// animation window's) end on ExitingEditMode, and their per-frame restore
// only lands when a frame actually renders. Starting in the same call would
// snapshot and swap the scene between a preview's apply and its restore, so
// tracks release at visibly different moments. `pending_start` gives every
// preview one clean frame to unwind before start() runs.
//
// Callers use this instead of start(); start() stays the immediate form for
// tests and anything that has already quiesced.
request_start :: proc(paused := false) {
    if _state != .Stopped do return
    _pending_start = true
    _pending_paused = paused
}

// Whether a start is queued for the next tick_pending call.
start_pending :: proc() -> bool {
    return _pending_start
}

// One call per editor frame, before the views draw: runs a queued start.
tick_pending :: proc() {
    if !_pending_start do return
    _pending_start = false
    start(_pending_paused)
}

@(private) _pending_start: bool
@(private) _pending_paused: bool

// Capture the open scene, then start ticking it. `paused` starts on frame zero
// without advancing, so the transition phases fire in the state callers observe.
start :: proc(paused := false) -> bool {
    if _state != .Stopped do return false
    if !available() {
        log.error("Simulate: no sim host")
        return false
    }

    // The world logs why a capture fails (no active scene, serialize error).
    snapshot, captured, ok := world_capture()
    if !ok do return false
    _snapshot = snapshot
    _scene = captured

    {
        context.allocator = runtime.default_allocator()
        clear(&_selection)
        if _hooks.selection_ids != nil {
            for id in _hooks.selection_ids() do append(&_selection, id)
        }
    }

    _fire(.ExitingEditMode)
    // From here undo only walks through what the run records (undo.play_begin).
    undo.play_begin(undo.get())
    _state = paused ? .Paused : .Running
    _sync_context()
    world_reset_time()
    _fire(.EnteredPlayMode)
    return true
}

// Roll the scene back to its state at Start.
stop :: proc() {
    _pending_start = false
    if _state == .Stopped do return

    _fire(.ExitingPlayMode)

    // Selection first, while its handles are still live, so the inspector and
    // gizmos let go before anything is destroyed.
    if _hooks.selection_clear != nil do _hooks.selection_clear()

    // The run's scene edits leave the undo stack: they target objects Stop
    // replaces. Edits from before Play stay and find their objects again in
    // the restored scene. Asset edits stay.
    undo.play_end(undo.get())

    // Back to the scene set of Start, then the captured scene reverts. Objects
    // the game destroyed are absent from the restored scene too, so they do
    // not resolve and drop out of the selection.
    if _snapshot != nil {
        if restored, ok := world_restore(_snapshot); ok {
            if _hooks.selection_add_id != nil {
                for id in _selection do _hooks.selection_add_id(restored, id)
            }
            clear(&_selection)
        } else {
            log.error("Simulate: snapshot restore failed - the scene was NOT restored; reopen it from Project")
        }
        world_release(_snapshot)
    }
    _snapshot = nil
    _scene = {}

    _state = .Stopped
    _sync_context()
    world_reset_time()
    _fire(.EnteredEditMode)
}

set_paused :: proc(paused: bool) {
    if _state == .Stopped do return
    _state = paused ? .Paused : .Running
    _sync_context()
}

toggle_pause :: proc() {
    switch _state {
    case .Running: set_paused(true)
    case .Paused:  set_paused(false)
    case .Stopped:
    }
}

// Advance one frame, then hold. From Running this pauses first; from Stopped it
// enters a held simulation.
step :: proc() {
    switch _state {
    case .Stopped:
        if !start(paused = true) do return
    case .Running:
        _state = .Paused
        _sync_context()
    case .Paused:
    }
    _step_pending = true
}

// Advance the simulation for one frame, in the app loop's order: fixed ticks from
// the accumulator, then the frame tick.
//
// A step advances exactly one fixed tick and one frame tick, ignoring the
// accumulator. A normal run uses it, so gameplay speed matches standalone.
tick :: proc(dt: f32) {
    if _state == .Stopped do return

    step := _step_pending
    _step_pending = false
    if !is_ticking() && !step do return

    host, ok := active_host()
    if !ok do return
    world_tick(dt, step, host.fixed_update, host.update)
}

hosts :: proc() -> []Host {
    return _hosts
}

host_index :: proc() -> int {
    return _host
}

active_host :: proc() -> (Host, bool) {
    if _host < 0 || _host >= len(_hosts) do return {}, false
    return _hosts[_host], true
}

// True when `name` is the active sim host. Generated host-owned phase entries
// are guarded with this (phase_editor_run, phases_generated.odin).
host_is :: proc(name: string) -> bool {
    h, ok := active_host()
    return ok && h.name == name
}

// Stops a running simulation first: a scene must not tick with another game's
// update set.
set_host :: proc(idx: int) {
    if idx < 0 || idx >= len(_hosts) do return
    if idx == _host do return
    if is_active() do stop()
    _host = idx
    if _hooks.host_name_store != nil do _hooks.host_name_store(_hosts[idx].name)
}

// False when no runnable package is installed. The editor depends on none, so
// zero hosts is a valid build.
available :: proc() -> bool {
    _, ok := active_host()
    return ok
}

// Feeds the world's "is playing". True from Start to Stop, paused included.
_sync_context :: proc() {
    world_set_playing(_state != .Stopped)
}

_fire :: proc(p: Phase) {
    if _hooks.phase != nil do _hooks.phase(p)
}
