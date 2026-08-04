package editor

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import input "../engine/input"
import "../engine"
import "../engine/log"
import "./undo"

// In-editor simulation: tick the OPEN scene in place, then roll it back.
//
// Distinct from the toolbar's Play button (run_app_play, view_toolbar.odin),
// which compiles a run config and launches the game as a separate process. That
// path is the only one that proves the game runs standalone — it gets the
// editor's allocator, input layer and views out of the way. Simulate keeps all
// of them, which is the point: everything stays inspectable while it runs.
//
// Revert rests on the snapshot being the SAME bytes a save writes
// (engine.scene_serialize). Capture is the save path and restore is the load
// path, so "can I revert" reduces to "can I save and load a scene" — which
// tests/resave_scenes already proves round-trips byte-identically. A private
// capture format would drift the moment a field was added.

Sim_State :: enum {
    Stopped,
    Running,
    Paused,
}

_sim_state: Sim_State

// Snapshot of the scene at Start, in the on-disk scene format. Held in memory
// only — the run-app path writes its own copy to library/, this one never
// touches the filesystem.
_sim_snapshot: []byte

// The scene the snapshot was taken from. Restore refuses to run against a
// different scene, so closing the scene mid-simulation cannot deserialize into
// an unrelated world.
_sim_scene: ^engine.Scene

// Scene path/guid restored alongside the objects: _scene_load_single mints a
// fresh Scene, so these would otherwise be lost and the tab would forget which
// file it is editing.
_sim_scene_path: string

// Selection captured as LOCAL IDs, not handles. Handles hold a pool slot +
// generation, and restore re-creates every object, so any handle kept across
// the boundary would dangle. Local ids survive because they are what the file
// stores.
_sim_selection: [dynamic]engine.Local_ID

// Set by Step, consumed by the next sim_tick: advance one frame, then re-pause.
// A latch rather than a direct tick because Step is pressed during UI
// submission, and ticking there would advance the world midway through a frame
// the views have already partly drawn.
_sim_step_pending: bool

sim_state :: proc() -> Sim_State {
    return _sim_state
}

sim_is_active :: proc() -> bool {
    return _sim_state != .Stopped
}

// True while the scene should advance. Paused freezes the sim without leaving
// it, so views keep drawing and the inspector keeps working.
sim_is_ticking :: proc() -> bool {
    return _sim_state == .Running
}

// Capture the open scene, then start ticking it.
sim_start :: proc(paused := false) -> bool {
    if _sim_state != .Stopped do return false
    if !sim_available() {
        log.error("Simulate: no tick dispatchers registered")
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

    _sim_snapshot = snapshot
    _sim_scene = scene
    _sim_scene_path = strings.clone(scene.path)

    clear(&_sim_selection)
    for tH in sel_scene_items() {
        if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)); t != nil {
            append(&_sim_selection, t.local_id)
        }
    }

    phase_editor_run(.ExitingEditMode)
    _sim_state = paused ? .Paused : .Running
    _sim_sync_context()
    engine.fixed_reset()
    phase_editor_run(.EnteredPlayMode)
    return true
}

// Roll the scene back to its pre-Start state.
sim_stop :: proc() {
    if _sim_state == .Stopped do return

    phase_editor_run(.ExitingPlayMode)

    // Selection goes first, while the handles it holds are still live: the
    // inspector and gizmos react to the clear, so they let go before anything
    // is destroyed rather than after.
    sel_scene_clear()

    // Drop scene-referencing undo entries BEFORE the scene goes away, while the
    // pointer is still valid — the same order every single-scene load uses.
    // This also discards anything recorded during the run: those commands
    // target objects that Stop is about to replace, and "Stop reverts" cannot
    // coexist with "undo back into the reverted world". Asset edits survive.
    if us := undo.get(); us != nil {
        undo.purge_scenes(us)
    }

    restored := false
    if _sim_snapshot != nil && _sim_scene != nil && engine.sm_scene_is_loaded(_sim_scene) {
        restored = _sim_restore()
    }
    if !restored && _sim_snapshot != nil {
        log.error("Simulate: snapshot restore failed - the scene was NOT restored; reopen it from Project")
    }

    delete(_sim_snapshot)
    _sim_snapshot = nil
    _sim_scene = nil
    if _sim_scene_path != "" {
        delete(_sim_scene_path)
        _sim_scene_path = ""
    }

    _sim_state = .Stopped
    _sim_sync_context()
    engine.fixed_reset()
    phase_editor_run(.EnteredEditMode)
}

sim_set_paused :: proc(paused: bool) {
    if _sim_state == .Stopped do return
    _sim_state = paused ? .Paused : .Running
    _sim_sync_context()
}

// Mirror the state machine onto the engine context, so component code can ask
// engine.application_is_playing() without knowing about the editor.
//
// True from Start until Stop, INCLUDING while paused - pause is a separate
// condition, not "not playing". Pause lives in sim_state()/_sim_state only.
_sim_sync_context :: proc() {
    if uc := engine.ctx_get(); uc != nil {
        uc.is_playing = _sim_state != .Stopped
    }
}

sim_toggle_pause :: proc() {
    switch _sim_state {
    case .Running: sim_set_paused(true)
    case .Paused:  sim_set_paused(false)
    case .Stopped:
    }
}

// Advance exactly one frame, then hold. Pressing Step while Running pauses
// first — Unity's behaviour, and the only reading that makes sense: stepping is
// a request to inspect one frame at a time.
//
// Step from Stopped starts the simulation paused on frame zero, so the button
// is a way IN to a stepped run, not just a control once inside.
sim_step :: proc() {
    switch _sim_state {
    case .Stopped:
        if !sim_start(paused = true) do return
    case .Running:
        _sim_state = .Paused
    case .Paused:
    }
    _sim_sync_context()
    _sim_step_pending = true
}

// Deserialize the snapshot back over the simulated scene, then re-resolve
// selection by local id.
//
// Scoped to that ONE scene (scene_reload_in_place_bytes): additively loaded
// scenes were never captured, so a whole-world reload would destroy them and be
// unable to bring them back. It also keeps the scene's slot and active status, so
// the editor keeps editing the same scene it was.
//
// On failure the target scene is already destroyed — restore cannot be atomic
// once the old contents are gone. Returns false so the caller reports it rather
// than pretending the scene is intact.
_sim_restore :: proc() -> bool {
    scene := engine.scene_reload_in_place_bytes(
        _sim_scene, _sim_snapshot, _sim_scene.asset_guid, _sim_scene_path)
    if scene == nil do return false

    // Re-resolve by local id. Objects the game destroyed at runtime are not in
    // the restored scene either, so they simply do not resolve — dropping them
    // is correct, not a failure.
    for lid in _sim_selection {
        if tH, ok := engine.scene_find_selectable_transform_local_id(scene, lid); ok {
            sel_scene_add(tH)
        }
    }
    clear(&_sim_selection)
    return true
}

// Which SIM HOST Simulate ticks — an index into sim_hosts (sim_hosts_generated.odin).
//
// The editor is not a host and links all of them, so unlike the app binary it
// has to choose. update_gen emits __update / __fixed_update per runnable package
// under a fixed name, so "the dispatcher" is ambiguous here in a way it never is
// inside a game: with two games installed, app.__update and game2.__update both
// exist. Picking one by hand is how the editor silently ticks the wrong game.
//
// Ticking goes through the chosen row's procs, which are the exact procs that
// host's own loop calls — so a component behaves identically in Simulate and
// standalone, and a new @(update) subscriber (including from a plugin) is picked
// up with no change here.
_sim_host: int

// Persisted in editor_settings.sim_host by name, since indices shift when a host
// is added or removed.
sim_host_index :: proc() -> int {
    return _sim_host
}

sim_host :: proc() -> (Sim_Host, bool) {
    if _sim_host < 0 || _sim_host >= len(sim_hosts) do return {}, false
    return sim_hosts[_sim_host], true
}

// True when `name` is the active sim host. Generated host-owned phase entries
// are guarded with this (phase_editor_run, phases_generated.odin).
sim_host_is :: proc(name: string) -> bool {
    h, ok := sim_host()
    return ok && h.name == name
}

// Selecting a different host mid-run would tick a scene with another game's
// update set, so the running simulation is stopped (and thus reverted) first.
sim_set_host :: proc(idx: int) {
    if idx < 0 || idx >= len(sim_hosts) do return
    if idx == _sim_host do return
    if sim_is_active() do sim_stop()
    _sim_host = idx
    if editor_settings.sim_host != "" do delete(editor_settings.sim_host)
    editor_settings.sim_host = strings.clone(sim_hosts[idx].name)
}

// Resolve the persisted host name to an index. Falls back to the first host, so
// a repo with exactly one game needs no setting and a renamed/removed host
// degrades to something valid rather than to nothing.
simulate_init :: proc() {
    _sim_host = 0
    if editor_settings.sim_host == "" do return
    for h, i in sim_hosts {
        if h.name == editor_settings.sim_host {
            _sim_host = i
            return
        }
    }
}

// True when Simulate can run at all: no runnable package means nothing to tick
// (the editor depends on no host, so zero is a valid build).
sim_available :: proc() -> bool {
    _, ok := sim_host()
    return ok
}

// Advance the simulation for one editor frame. Mirrors the app loop's ordering
// (fixed ticks from the accumulator, then the per-frame tick) so component code
// sees the same shape here as it does standalone.
sim_tick :: proc(dt: f32) {
    if _sim_state == .Stopped do return

    step := _sim_step_pending
    _sim_step_pending = false
    if !sim_is_ticking() && !step do return

    host, ok := sim_host()
    if !ok do return

    // A step advances by exactly one fixed tick and one frame tick, ignoring the
    // accumulator: a step should be a unit of simulation, not "however much wall
    // clock passed while you were reading the inspector". Running uses the real
    // accumulator so gameplay speed matches standalone.
    fdt := engine.fixed_dt()
    steps := 1 if step else engine.fixed_frame_ticks(dt)
    for _ in 0 ..< steps {
        input.fixed_latch()
        if host.fixed_update != nil do host.fixed_update(fdt)
        engine.fixed_tick_advance()
    }
    if host.update != nil do host.update(fdt if step else dt)
}

// Cmd/Ctrl+P toggles Simulate, Cmd/Ctrl+Shift+P pauses — Unity's chords.
// Routed globally so they work regardless of which view has focus, and checked
// before the views draw so a Stop lands before the tick (see main.odin).
_process_simulate_shortcuts :: proc() {
    toggle := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.P)
    pause := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.P)

    // Shift variant first: the plain chord is a prefix of it, so testing the
    // plain one first would swallow the pause chord.
    if im.Shortcut(pause, {.RouteGlobal}) {
        sim_toggle_pause()
        return
    }
    if im.Shortcut(toggle, {.RouteGlobal}) {
        if sim_is_active() {
            sim_stop()
        } else {
            sim_start()
        }
    }
}

// Toolbar: Simulate / Pause / Step, always all three — Unity's layout. Sits
// beside the existing Play button, which keeps its own meaning (build and launch
// the game as a process).
//
// Every button stays visible and enabled at all times, so the cluster never
// changes width and no control moves under the cursor. Unity does the same: its
// Pause and Step are live while stopped, because pressing them is a valid way to
// ENTER a paused or stepped run.
_draw_simulate_controls :: proc() {
    style := im.GetStyle()

    active := sim_is_active()
    paused := _sim_state == .Paused

    // Slots are sized to their widest glyph so a button never changes width when
    // its icon swaps, which would nudge everything to its right mid-run.
    pad := style.FramePadding.x * 2
    sim_slot := im.Vec2{
        max(im.CalcTextSize(ICON_MD_PLAY_ARROW, nil, false, -1).x,
            im.CalcTextSize(ICON_MD_STOP, nil, false, -1).x) + pad,
        0,
    }
    pause_slot := im.Vec2{
        max(im.CalcTextSize(ICON_MD_PAUSE, nil, false, -1).x,
            im.CalcTextSize(ICON_MD_PLAY_CIRCLE, nil, false, -1).x) + pad,
        0,
    }

    // Simulate doubles as Stop once running, mirroring the way Unity's Play
    // button becomes the stop control.
    _push_sim_button_bg(active)
    if im.ButtonWithFlags(active \
        ? ICON_MD_STOP + "###SimToggle" \
        : ICON_MD_PLAY_ARROW + "###SimToggle", sim_slot) {
        if active {
            sim_stop()
        } else {
            sim_start()
        }
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        im.SetTooltip(active \
            ? "Stop simulating (Cmd/Ctrl+P) - restores the scene to its state at Simulate" \
            : "Simulate this scene in the editor (Cmd/Ctrl+P) - everything stays inspectable")
    }

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.ButtonWithFlags(paused \
        ? ICON_MD_PLAY_CIRCLE + "###SimPause" \
        : ICON_MD_PAUSE + "###SimPause", pause_slot) {
        if active {
            sim_toggle_pause()
        } else {
            // Pause from Stopped enters a paused run, so the scene is captured
            // and sitting on frame zero rather than nothing happening.
            sim_start(paused = true)
        }
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        if !active {
            im.SetTooltip("Simulate paused (Cmd/Ctrl+Shift+P)")
        } else {
            im.SetTooltip(paused ? "Resume (Cmd/Ctrl+Shift+P)" : "Pause (Cmd/Ctrl+Shift+P)")
        }
    }

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.Button(ICON_MD_SKIP_NEXT + "###SimStep") {
        sim_step()
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        im.SetTooltip("Step one frame - pauses first if running")
    }
}

// Which game Simulate ticks (the "sim host"). Always drawn, disabled when there
// is nothing to
// choose (0 or 1 host), so the control does not appear and disappear — with one
// game it reads out that game's name, which is the useful thing about it.
_draw_sim_host_combo :: proc() {
    host, has_host := sim_host()

    preview: cstring = "No sim host"
    if has_host do preview = strings.clone_to_cstring(host.name, context.temp_allocator)

    im.BeginDisabled(len(sim_hosts) < 2)
    im.SetNextItemWidth(_sim_host_combo_width())
    if im.BeginCombo("##sim_host", preview, {}) {
        for h, i in sim_hosts {
            label := strings.clone_to_cstring(h.name, context.temp_allocator)
            if im.Selectable(label, i == _sim_host) {
                sim_set_host(i)
            }
        }
        im.EndCombo()
    }
    im.EndDisabled()
    if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
        switch len(sim_hosts) {
        case 0:
            im.SetTooltip("No runnable package found (a game is a package with main at its root)")
        case 1:
            im.SetTooltip(fmt.ctprintf(
                "Simulate ticks %s - the only installed game", host.name))
        case:
            im.SetTooltip("Sim host: the game whose update code Simulate runs")
        }
    }
}

// Sized to the widest host name so switching hosts never shifts the toolbar,
// matching how the run-config combo is measured.
_sim_host_combo_width :: proc() -> f32 {
    style := im.GetStyle()
    w := im.CalcTextSize("No sim host", nil, false, -1).x
    for h in sim_hosts {
        name := strings.clone_to_cstring(h.name, context.temp_allocator)
        w = max(w, im.CalcTextSize(name, nil, false, -1).x)
    }
    return w + style.FramePadding.x * 2 + im.GetFrameHeight()
}

// Highlight a toolbar toggle that is currently ON. Uses the theme's active
// button colour rather than a literal, so it follows the theme.
// Simulate's accent. Orange so an active simulation is unmistakable at a glance:
// the toolbar's other controls are theme-neutral, and mistaking a running sim for
// a stopped editor is the expensive confusion (edits get reverted on Stop).
//
// Pushed as Button/Hovered/Active together, so the pressed state stays a shade of
// the accent rather than snapping back to the theme's blue.
SIM_ACCENT         :: im.Vec4{0.85, 0.42, 0.10, 1.00}
SIM_ACCENT_HOVERED :: im.Vec4{0.95, 0.52, 0.16, 1.00}
SIM_ACCENT_ACTIVE  :: im.Vec4{0.72, 0.34, 0.06, 1.00}

// `on` tints the button with the accent; off leaves the theme colours alone, so
// an idle toolbar looks like the rest of the editor. Always pushes 3 colours —
// pair with _pop_sim_button_bg.
//
// Every simulate button passes the SAME condition (a run is active), so the whole
// cluster lights up together: the accent marks the editor's state, not which
// individual button is toggled.
_push_sim_button_bg :: proc(on: bool) {
    style := im.GetStyle()
    if on {
        im.PushStyleColorImVec4(.Button, SIM_ACCENT)
        im.PushStyleColorImVec4(.ButtonHovered, SIM_ACCENT_HOVERED)
        im.PushStyleColorImVec4(.ButtonActive, SIM_ACCENT_ACTIVE)
    } else {
        im.PushStyleColorImVec4(.Button, style.Colors[im.Col.Button])
        im.PushStyleColorImVec4(.ButtonHovered, style.Colors[im.Col.ButtonHovered])
        im.PushStyleColorImVec4(.ButtonActive, style.Colors[im.Col.ButtonActive])
    }
}

_pop_sim_button_bg :: proc() {
    im.PopStyleColor(3)
}

// Total width of the cluster. Constant across every run state, because each slot
// is sized to its widest glyph (see _draw_simulate_controls) — so centering the
// toolbar never shifts when Simulate starts or pauses.
_simulate_controls_width :: proc() -> f32 {
    style := im.GetStyle()
    pad := style.FramePadding.x * 2

    sim_w := max(im.CalcTextSize(ICON_MD_PLAY_ARROW, nil, false, -1).x,
                 im.CalcTextSize(ICON_MD_STOP, nil, false, -1).x)
    pause_w := max(im.CalcTextSize(ICON_MD_PAUSE, nil, false, -1).x,
                   im.CalcTextSize(ICON_MD_PLAY_CIRCLE, nil, false, -1).x)
    step_w := im.CalcTextSize(ICON_MD_SKIP_NEXT, nil, false, -1).x

    return sim_w + pause_w + step_w + pad * 3 + style.ItemSpacing.x * 2
}

simulate_shutdown :: proc() {
    // Stop rather than just freeing: the scene should not be left holding
    // gameplay state on the way out, and Stop is the only path that restores.
    if _sim_state != .Stopped {
        sim_stop()
    }
    delete(_sim_selection)
    _sim_selection = nil
}
