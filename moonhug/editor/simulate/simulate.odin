package simulate

// In-editor simulation: tick the open scene in place, then roll it back.
// See docs/Simulate.md.
//
// Logic only, with no imgui or view dependency, so tests and tools drive a
// simulation without the editor root. Toolbar: editor/simulate_view.odin.
//
// The snapshot is the same bytes a save writes: capture is scene_serialize,
// restore is scene_reload_in_place_bytes.

import "core:strings"
import "moonhug:engine"
import "moonhug:engine/log"
import input "moonhug:engine/input"
import "moonhug:editor/undo"

State :: enum {
    Stopped,
    Running,
    Paused,
}

// One runnable package the editor can tick. Rows come from the generated table
// (editor/sim_hosts_generated.odin), passed to install.
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
    selection_ids:     proc() -> []engine.Local_ID, // ids to restore after Stop
    selection_clear:   proc(),
    selection_add_id:  proc(s: ^engine.Scene, id: engine.Local_ID),
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

// The scene at Start, in the on-disk scene format, held in memory.
_snapshot: []byte
_scene: ^engine.Scene
_scene_path: string

// Ids of the objects selected at Start. Handles hold a pool slot + generation and
// restore re-creates every object, so ids are what survives.
_selection: [dynamic]engine.Local_ID

// Set by step, consumed by the next tick: advance one frame, then hold.
_step_pending: bool

install :: proc(hooks: Hooks, hosts: []Host) {
    _hooks = hooks
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

// True while the scene advances. Paused holds the world without leaving.
is_ticking :: proc() -> bool {
    return _state == .Running
}

// Capture the open scene, then start ticking it. `paused` starts on frame zero
// without advancing, so the transition phases fire in the state callers observe.
start :: proc(paused := false) -> bool {
    if _state != .Stopped do return false
    if !available() {
        log.error("Simulate: no sim host")
        return false
    }

    scene := engine.sm_scene_get_active()
    if scene == nil {
        log.error("Simulate: no active scene")
        return false
    }

    snapshot, ok := engine.scene_serialize(scene)
    if !ok {
        log.error("Simulate: failed to capture scene snapshot")
        return false
    }

    _snapshot = snapshot
    _scene = scene
    _scene_path = strings.clone(scene.path)

    clear(&_selection)
    if _hooks.selection_ids != nil {
        for id in _hooks.selection_ids() do append(&_selection, id)
    }

    _fire(.ExitingEditMode)
    _state = paused ? .Paused : .Running
    _sync_context()
    engine.fixed_reset()
    _fire(.EnteredPlayMode)
    return true
}

// Roll the scene back to its state at Start.
stop :: proc() {
    if _state == .Stopped do return

    _fire(.ExitingPlayMode)

    // Selection first, while its handles are still live, so the inspector and
    // gizmos let go before anything is destroyed.
    if _hooks.selection_clear != nil do _hooks.selection_clear()

    // Scene-referencing undo entries go while the scene pointer is still valid.
    // This also drops what the run recorded, since those commands target objects
    // Stop replaces. Asset edits survive.
    if us := undo.get(); us != nil {
        undo.purge_scenes(us)
    }

    restored := false
    if _snapshot != nil && _scene != nil && engine.sm_scene_is_loaded(_scene) {
        restored = _restore()
    }
    if !restored && _snapshot != nil {
        log.error("Simulate: snapshot restore failed - the scene was NOT restored; reopen it from Project")
    }

    delete(_snapshot)
    _snapshot = nil
    _scene = nil
    if _scene_path != "" {
        delete(_scene_path)
        _scene_path = ""
    }

    _state = .Stopped
    _sync_context()
    engine.fixed_reset()
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

    fdt := engine.fixed_dt()
    steps := 1 if step else engine.fixed_frame_ticks(dt)
    for _ in 0 ..< steps {
        input.fixed_latch()
        if host.fixed_update != nil do host.fixed_update(fdt)
        engine.fixed_tick_advance()
    }
    if host.update != nil do host.update(fdt if step else dt)
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

// Deserialize the snapshot back over the simulated scene, then re-resolve
// selection by id. Scoped to that one scene, keeping its slot and active status;
// additively loaded scenes are untouched.
//
// Not atomic: on failure the target scene is already destroyed.
_restore :: proc() -> bool {
    scene := engine.scene_reload_in_place_bytes(
        _scene, _snapshot, _scene.asset_guid, _scene_path)
    if scene == nil do return false

    // Objects the game destroyed are absent from the restored scene too, so they
    // do not resolve and drop out of the selection.
    if _hooks.selection_add_id != nil {
        for id in _selection do _hooks.selection_add_id(scene, id)
    }
    clear(&_selection)
    return true
}

// Feeds engine.application_is_playing(). True from Start to Stop, paused
// included.
_sync_context :: proc() {
    if uc := engine.ctx_get(); uc != nil {
        uc.is_playing = _state != .Stopped
    }
}

_fire :: proc(p: Phase) {
    if _hooks.phase != nil do _hooks.phase(p)
}
