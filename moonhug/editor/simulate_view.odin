package editor

// Toolbar and shortcuts for in-editor simulation (docs/Simulate.md). The state
// machine lives in editor/simulate; this file is its view plus the hooks that
// give it access to editor-root state (selection, phases, settings).

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "../engine"
import sim "./simulate"

// Simulate's accent, on every simulate button while a run is active. The rest of
// the toolbar is theme-neutral.
SIM_ACCENT         :: im.Vec4{0.85, 0.42, 0.10, 1.00}
SIM_ACCENT_HOVERED :: im.Vec4{0.95, 0.52, 0.16, 1.00}
SIM_ACCENT_ACTIVE  :: im.Vec4{0.72, 0.34, 0.06, 1.00}

simulate_init :: proc() {
    hosts := make([]sim.Host, len(sim_hosts))
    for h, i in sim_hosts {
        hosts[i] = sim.Host{
            name = h.name, path = h.path,
            update = h.update, fixed_update = h.fixed_update,
        }
    }
    sim.install(sim.Hooks{
        selection_ids    = _sim_selection_ids,
        selection_clear  = sel_scene_clear,
        selection_add_id = _sim_selection_add_id,
        phase            = _sim_fire_phase,
        host_name_load   = _sim_host_name_load,
        host_name_store  = _sim_host_name_store,
    }, hosts)
}

simulate_shutdown :: proc() {
    sim.shutdown()
    delete(sim.hosts())
}

// True when `name` is the active sim host. Generated host-owned phase entries
// call this (phase_editor_run, phases_generated.odin).
sim_host_is :: proc(name: string) -> bool {
    return sim.host_is(name)
}

sim_tick :: proc(dt: f32) {
    sim.tick(dt)
}

@(private="file")
_sim_selection_ids :: proc() -> []engine.Local_ID {
    out := make([dynamic]engine.Local_ID, context.temp_allocator)
    for tH in sel_scene_items() {
        if t := engine.pool_get(&engine.ctx_world().transforms, engine.Handle(tH)); t != nil {
            append(&out, t.local_id)
        }
    }
    return out[:]
}

@(private="file")
_sim_selection_add_id :: proc(s: ^engine.Scene, id: engine.Local_ID) {
    if tH, ok := engine.scene_find_selectable_transform_local_id(s, id); ok {
        sel_scene_add(tH)
    }
}

@(private="file")
_sim_fire_phase :: proc(p: sim.Phase) {
    switch p {
    case .ExitingEditMode: phase_editor_run(.ExitingEditMode)
    case .EnteredPlayMode: phase_editor_run(.EnteredPlayMode)
    case .ExitingPlayMode: phase_editor_run(.ExitingPlayMode)
    case .EnteredEditMode: phase_editor_run(.EnteredEditMode)
    }
}

@(private="file")
_sim_host_name_load :: proc() -> string {
    return editor_settings.sim_host
}

@(private="file")
_sim_host_name_store :: proc(name: string) {
    if editor_settings.sim_host != "" do delete(editor_settings.sim_host)
    editor_settings.sim_host = strings.clone(name)
}

// Cmd/Ctrl+P toggles Simulate, Cmd/Ctrl+Shift+P pauses. Routed globally so they
// work regardless of which view has focus.
_process_simulate_shortcuts :: proc() {
    toggle := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.P)
    pause := im.KeyChord(im.Key.ImGuiMod_Ctrl) | im.KeyChord(im.Key.ImGuiMod_Shift) | im.KeyChord(im.Key.P)

    // Shift variant first: the plain chord is a prefix of it.
    if im.Shortcut(pause, {.RouteGlobal}) {
        sim.toggle_pause()
        return
    }
    if im.Shortcut(toggle, {.RouteGlobal}) {
        if sim.is_active() {
            sim.stop()
        } else {
            sim.start()
        }
    }
}

// Simulate / Pause / Step, all three always visible and enabled. Pressing Pause
// or Step while stopped enters a held run.
_draw_simulate_controls :: proc() {
    style := im.GetStyle()

    active := sim.is_active()
    paused := sim.state() == .Paused

    // Slots sized to their widest glyph, so a button keeps its width when its
    // icon swaps and nothing to the right shifts.
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

    _push_sim_button_bg(active)
    if im.ButtonWithFlags(active \
        ? ICON_MD_STOP + "###SimToggle" \
        : ICON_MD_PLAY_ARROW + "###SimToggle", sim_slot) {
        if active {
            sim.stop()
        } else {
            sim.start()
        }
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        im.SetTooltip(active ? "Stop (Cmd/Ctrl+P)" : "Play (Cmd/Ctrl+P)")
    }

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.ButtonWithFlags(paused \
        ? ICON_MD_PLAY_CIRCLE + "###SimPause" \
        : ICON_MD_PAUSE + "###SimPause", pause_slot) {
        if active {
            sim.toggle_pause()
        } else {
            sim.start(paused = true)
        }
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        im.SetTooltip(active && paused ? "Resume (Cmd/Ctrl+Shift+P)" : "Pause (Cmd/Ctrl+Shift+P)")
    }

    im.SameLine(0, style.ItemSpacing.x)
    _push_sim_button_bg(active)
    if im.Button(ICON_MD_SKIP_NEXT + "###SimStep") {
        sim.step()
    }
    _pop_sim_button_bg()
    if im.IsItemHovered({}) {
        im.SetTooltip("Step Frame")
    }
}

// Which game Simulate ticks. Always drawn, disabled below two hosts, where it
// reads out the sole game's name.
_draw_sim_host_combo :: proc() {
    host, has_host := sim.active_host()
    all := sim.hosts()

    preview: cstring = "No sim host"
    if has_host do preview = strings.clone_to_cstring(host.name, context.temp_allocator)

    im.BeginDisabled(len(all) < 2)
    im.SetNextItemWidth(_sim_host_combo_width())
    if im.BeginCombo("##sim_host", preview, {}) {
        for h, i in all {
            label := strings.clone_to_cstring(h.name, context.temp_allocator)
            if im.Selectable(label, i == sim.host_index()) {
                sim.set_host(i)
            }
        }
        im.EndCombo()
    }
    im.EndDisabled()
    if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
        switch len(all) {
        case 0:
            im.SetTooltip("No runnable package found (a game is a package with main at its root)")
        case 1:
            im.SetTooltip(fmt.ctprintf("Sim host: %s (only game installed)", host.name))
        case:
            im.SetTooltip("Sim host: which game's code Simulate runs")
        }
    }
}

// Sized to the widest host name, so switching hosts does not shift the toolbar.
_sim_host_combo_width :: proc() -> f32 {
    style := im.GetStyle()
    w := im.CalcTextSize("No sim host", nil, false, -1).x
    for h in sim.hosts() {
        name := strings.clone_to_cstring(h.name, context.temp_allocator)
        w = max(w, im.CalcTextSize(name, nil, false, -1).x)
    }
    return w + style.FramePadding.x * 2 + im.GetFrameHeight()
}

// `on` tints with the accent, off keeps the theme colours. Every simulate button
// passes the same condition. Pushes 3 colours: pair with _pop_sim_button_bg.
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

// Total width of the cluster, constant across every run state.
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
