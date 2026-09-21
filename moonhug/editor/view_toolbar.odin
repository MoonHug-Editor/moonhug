package editor

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/runconfig"
import "../engine"
import "../engine/log"
import "moonhug:editor/icons"
import "moonhug:editor/widgets"

// The toolbar's own vertical padding. Tighter than WindowPadding so the bar
// hugs its buttons (Unity's toolbar), and the same in every theme.
TOOLBAR_PAD_Y :: 4

// One row of framed widgets plus the toolbar padding, from the live style and
// font so a theme's FramePadding or a font change never clips the buttons.
toolbar_height :: proc() -> f32 {
	return im.GetFrameHeight() + TOOLBAR_PAD_Y * 2
}

// Live-state play snapshot lives in library/ (never assets/): the AssetDB
// walk must not see it, or refresh would mint a guid for a transient file.
_PLAY_SCENE_SNAPSHOT_PATH :: "library/state_cache/play_scene_snapshot.scene"

_play_thread: ^thread.Thread

// Which stage the play thread is in, so the toolbar can say "Compiling" for the
// several seconds of `odin build` instead of claiming the game is already
// running. Written by the play thread, read by the UI thread every frame —
// atomic because that is a cross-thread scalar, not because the two ever race
// for a decision.
Play_Phase :: enum i32 {
    Idle,
    Compiling,
    Running,
}

_play_phase: Play_Phase

// A run configuration = one Odin PROGRAM in a package's run_configs/ folder
// (docs/Plugins.md). The Play button compiles the selected one and runs it from
// the REPO ROOT with the scene snapshot path as its argument; the config builds
// and runs the game, forwarding that argument. Odin rather than sh because Odin
// is already a hard dependency, so configs work on every OS the editor does.
Run_Config :: struct {
    id:     string,  // "pkg/name" — persisted in editor_settings.run_config
    label:  cstring, // "pkg: name" — dropdown row
    source: string,  // repo-root-relative path to the config's .odin file
}

_run_configs: [dynamic]Run_Config

// Editor cwd is normalized to moonhug/, so packages sit at "packages" and
// config source paths get the "moonhug/" prefix back for the repo-root spawn.
_scan_run_configs :: proc() {
    for &rc in _run_configs {
        delete(rc.id)
        delete(rc.label)
        delete(rc.source)
    }
    clear(&_run_configs)

    pkgs_dir, err := os.open("packages")
    if err != nil do return
    defer os.close(pkgs_dir)
    pkgs, rerr := os.read_dir(pkgs_dir, -1, context.temp_allocator)
    if rerr != nil do return
    defer os.file_info_slice_delete(pkgs, context.temp_allocator)

    for pkg in pkgs {
        // Symlinked packages (samples installed via symlink) read as
        // .Symlink — follow them like every other package scan.
        if pkg.type != .Directory {
            full, _ := filepath.join({"packages", pkg.name}, context.temp_allocator)
            if pkg.type != .Symlink || !os.is_dir(full) do continue
        }
        rc_path, _ := filepath.join({"packages", pkg.name, "run_configs"}, context.temp_allocator)
        rc_dir, rc_err := os.open(rc_path)
        if rc_err != nil do continue
        defer os.close(rc_dir)
        files, f_err := os.read_dir(rc_dir, -1, context.temp_allocator)
        if f_err != nil do continue
        defer os.file_info_slice_delete(files, context.temp_allocator)
        for file in files {
            if file.type == .Directory || !strings.has_suffix(file.name, ".odin") do continue
            name := strings.trim_suffix(file.name, ".odin")
            append(&_run_configs, Run_Config{
                id     = fmt.aprintf("%s/%s", pkg.name, name),
                label  = fmt.caprintf("%s: %s", pkg.name, name),
                source = fmt.aprintf("moonhug/packages/%s/run_configs/%s", pkg.name, file.name),
            })
        }
    }
}

// Selected config, resolving the persisted id; empty selection prefers the
// debug config (call-stack capture for console logs), then the first.
_selected_run_config :: proc() -> ^Run_Config {
    for &rc in _run_configs {
        if rc.id == editor_settings.run_config do return &rc
    }
    for &rc in _run_configs {
        if strings.has_suffix(rc.id, "run_debug") do return &rc
    }
    if len(_run_configs) > 0 do return &_run_configs[0]
    return nil
}

_select_run_config :: proc(id: string) {
    if editor_settings.run_config != "" do delete(editor_settings.run_config)
    editor_settings.run_config = strings.clone(id)
}

// --- Composition -------------------------------------------------------------
//
// The toolbar is COMPOSED from registered items, not drawn by one proc:
//
//   @(toolbar={zone="center", order=0}) on proc()  -> a widget in that zone
//
// Three zones. Left starts at the window edge, center is centred on the bar,
// right ends at the window edge. Items sort by order inside a zone. Every
// control the editor ships is itself a registered item (simulate_view.odin and
// below), so a plugin's button and the Play button reach the bar the same way,
// and there is no built-in list that a package would have to be spliced into.
//
// Zone widths are measured by drawing the items once off-screen per frame, the
// way the view tab bar does (view_chrome.odin). An item therefore declares no
// width, but it should keep its own width state-independent (size a button
// slot to its widest glyph) or the zone shifts as it changes.

Toolbar_Zone :: enum { Left, Center, Right }

Toolbar_Item :: struct {
    zone:   Toolbar_Zone,
    draw:   proc(),
    order:  int,
    // The @(toolbar) that created the item, as rendered by the generator.
    // Shown in the item's tooltip with debug tooltips on.
    origin: string,
}

@(private = "file") _toolbar_items: [dynamic]Toolbar_Item

// Registered once at startup from view_chrome_generated.odin. Process-global,
// so never borrows the caller's allocator.
toolbar_add_item :: proc(zone: Toolbar_Zone, draw: proc(), order := 0, origin := "") {
    context.allocator = runtime.default_allocator()
    append(&_toolbar_items, Toolbar_Item{zone = zone, draw = draw, order = order, origin = origin})
}

toolbar_shutdown :: proc() {
    context.allocator = runtime.default_allocator()
    delete(_toolbar_items)
    _toolbar_items = nil
}

@(private = "file")
_toolbar_items_for :: proc(zone: Toolbar_Zone) -> []Toolbar_Item {
    out := make([dynamic]Toolbar_Item, context.temp_allocator)
    for it in _toolbar_items do if it.zone == zone && it.draw != nil do append(&out, it)
    slice.sort_by(out[:], proc(a, b: Toolbar_Item) -> bool { return a.order < b.order })
    return out[:]
}

// Draws a zone's items from where the cursor is. Items are separated by
// ItemSpacing, and each draws under its origin so debug tooltips can name the
// attribute that registered it.
@(private = "file")
_toolbar_draw_items :: proc(items: []Toolbar_Item) {
    for it, i in items {
        if i > 0 do im.SameLine(0, im.GetStyle().ItemSpacing.x)
        prev := widgets.ui_origin_push(it.origin)
        it.draw()
        widgets.ui_origin_pop(prev)
    }
}

// Width of a zone, by drawing it once off-screen. Its own id scope, or every
// item exists twice under one id and imgui reports the conflict.
@(private = "file")
_toolbar_measure :: proc(items: []Toolbar_Item) -> f32 {
    if len(items) == 0 do return 0
    start := im.GetCursorPos()
    im.SetCursorPos(im.Vec2{-10000, start.y})
    im.PushID("##measure")
    im.BeginGroup()
    _toolbar_draw_items(items)
    im.EndGroup()
    w := im.GetItemRectSize().x
    im.PopID()
    im.SetCursorPos(start)
    return w
}

draw_tool_bar :: proc() {
    vp := im.GetMainViewport()
    im.SetNextWindowPos(vp.WorkPos, {}, {0, 0})
    im.SetNextWindowSize(im.Vec2{vp.WorkSize.x, toolbar_height()}, {})
    im.PushStyleVarImVec2(.WindowPadding, im.Vec2{im.GetStyle().WindowPadding.x, TOOLBAR_PAD_Y})
    open := im.Begin("##ToolBar", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoDocking})
    im.PopStyleVar()
    if !open do return
    defer im.End()

    if len(_run_configs) == 0 do _scan_run_configs()

    style := im.GetStyle()
    avail := im.GetContentRegionAvail().x
    // GetContentRegionAvail is a WIDTH and SetCursorPosX takes a POSITION, so
    // the right edge is this start plus that width.
    content_x := im.GetCursorPosX()

    zones: [Toolbar_Zone][]Toolbar_Item
    widths: [Toolbar_Zone]f32
    for z in Toolbar_Zone {
        zones[z] = _toolbar_items_for(z)
        widths[z] = _toolbar_measure(zones[z])
    }

    // Center is centred on the bar, right ends at its edge. Both are clamped
    // to sit after whatever came before, so a narrow window degrades to "as
    // far along as fits" instead of overlapping.
    targets := [Toolbar_Zone]f32{
        .Left   = content_x,
        .Center = content_x + (avail - widths[.Center]) * 0.5,
        .Right  = content_x + avail - widths[.Right],
    }
    drew := false
    for z in Toolbar_Zone {
        if len(zones[z]) == 0 do continue
        x := targets[z]
        if drew {
            im.SameLine(0, 0)
            x = max(x, im.GetCursorPosX() + style.ItemSpacing.x)
        }
        im.SetCursorPosX(x)
        _toolbar_draw_items(zones[z])
        drew = true
    }
}

// --- The editor's own items ----------------------------------------------------
//
// Widths are state-independent: each button slot is sized to its widest glyph
// and the combo to its widest label, so the bar never shifts when a run starts
// or a config is picked.

MOD_HINT :: "\nAlt: dev run (no export), Shift: run last build, Alt+Shift: build only"
NO_CONFIGS :: cstring("No run configs")

// Explicit ### ids: the labels are icon-only, and imgui derives ids from
// labels, so a Simulate button showing the same glyph would share the id.
BUTTON_PLAY_TEXT :: cstring(icons.ICON_MD_RUN_CONFIG + "###RunConfigPlay")
BUTTON_SCENE_TEXT :: cstring(icons.ICON_MD_CONSTRUCTION + "###BuildRunCurrentScene")

@(private = "file")
_toolbar_button_size :: proc(label: cstring) -> im.Vec2 {
    style := im.GetStyle()
    // hide_text_after_double_hash: the ### id suffix is not drawn, so it must
    // not be measured either.
    size := im.CalcTextSize(label, nil, true, -1)
    size.x += style.FramePadding.x * 2
    size.y += style.FramePadding.y * 2
    return size
}

// Build & Run with the CURRENT scene state (the live snapshot, forwarded to
// the run only, the staged data is always the config's own build). Sits with
// the simulate controls: both act on the scene as it is now.
@(toolbar={zone="center", order=20})
_toolbar_build_run_scene :: proc() {
    sel := _selected_run_config()
    if im.Button(BUTTON_SCENE_TEXT) && sel != nil {
        run_app_play(sel.id, sel.source, with_current_scene = true, mode = _run_mode_from_modifiers())
    }
    tip: cstring = "No run configs found (packages/*/run_configs/*.odin)"
    if sel != nil do tip = fmt.ctprintf("Build & Run with current scene state (%s)" + MOD_HINT, sel.label)
    widgets.tooltip(tip)
}

// The phase label sits LEFT of Play, so a long "(compiling)" grows inward
// instead of off the right edge. Then the config verbatim: its own pinned
// scene, the same build a bare launch produces.
@(toolbar={zone="right", order=0})
_toolbar_play :: proc() {
    phase_text: cstring = nil
    switch sync.atomic_load(&_play_phase) {
    case .Compiling: phase_text = "(compiling)"
    case .Running:   phase_text = "(running)"
    case .Idle:
    }
    if phase_text != nil {
        im.AlignTextToFramePadding()
        im.TextDisabled(phase_text)
        im.SameLine(0, im.GetStyle().ItemSpacing.x)
    }

    sel := _selected_run_config()
    if im.Button(BUTTON_PLAY_TEXT) && sel != nil {
        run_app_play(sel.id, sel.source, mode = _run_mode_from_modifiers())
    }
    tip: cstring = "No run configs found (packages/*/run_configs/*.odin)"
    if sel != nil do tip = fmt.ctprintf("Build & Run (%s)" + MOD_HINT, sel.label)
    widgets.tooltip(tip)
}

@(toolbar={zone="right", order=10})
_toolbar_run_config :: proc() {
    style := im.GetStyle()
    sel := _selected_run_config()
    preview := NO_CONFIGS
    if sel != nil do preview = sel.label

    // Sized to the WIDEST config, not the selected one, so switching configs
    // never shifts the toolbar. GetFrameHeight is the combo's square arrow box.
    combo_w := im.CalcTextSize(NO_CONFIGS, nil, false, -1).x
    for &rc in _run_configs {
        combo_w = max(combo_w, im.CalcTextSize(rc.label, nil, false, -1).x)
    }
    combo_w += style.FramePadding.x * 2 + im.GetFrameHeight()

    im.SetNextItemWidth(combo_w)
    if im.BeginCombo("##run_config", preview, {}) {
        // Rescan on open to pick up new/removed configs. That frees every label
        // and id, so `sel` points into released memory until it is recomputed.
        if im.IsWindowAppearing() {
            _scan_run_configs()
            sel = _selected_run_config()
        }
        for &rc in _run_configs {
            if im.Selectable(rc.label, sel != nil && sel.id == rc.id) {
                _select_run_config(rc.id)
            }
        }
        im.EndCombo()
    }
    widgets.tooltip("Run configuration")
}

// Relaunch: rebuild and restart the editor the way it was started
// (editor/relaunch.odin). The separator keeps it apart from the run configs,
// which build and run the GAME. Last in the zone, so it is the far-right item.
@(toolbar={zone="right", order=20})
_toolbar_relaunch :: proc() {
    im.SeparatorEx({.Vertical})
    im.SameLine(0, im.GetStyle().ItemSpacing.x)
    pending := relaunch_pending()
    im.BeginDisabled(pending)
    if im.Button(icons.ICON_MD_REFRESH, _toolbar_button_size(BUTTON_PLAY_TEXT)) do relaunch_request()
    im.EndDisabled()
    widgets.tooltip(
        pending \
            ? fmt.ctprintf("Relaunch Editor\nbuilding: %s", relaunch_command()) \
            : fmt.ctprintf("Relaunch Editor\n%s", relaunch_command()),
        im.HoveredFlags_AllowWhenDisabled)
}

RunPlayData :: struct {
    alloc:         mem.Allocator,
    run_dir:       string,
    build_command: []string, // compile the run config
    run_command:   []string, // then execute it, with the scene snapshot appended
}

_destroy_run_play_data :: proc(data: ^RunPlayData) {
    a := data.alloc
    delete(data.run_dir, a)
    _delete_command(data.build_command, a)
    _delete_command(data.run_command, a)
    free(data, a)
}

// Commands cross a thread boundary and outlive the frame that built them, so
// every element is owned rather than borrowed from temp storage.
@(private="file")
_clone_command :: proc(parts: []string, a: mem.Allocator) -> []string {
    out, err := make([]string, len(parts), a)
    if err != nil do return nil
    for p, i in parts {
        out[i], _ = strings.clone(p, a)
    }
    return out
}

@(private="file")
_delete_command :: proc(cmd: []string, a: mem.Allocator) {
    for s in cmd do delete(s, a)
    delete(cmd, a)
}

// Runs one child to completion on the given pipe write-ends, returning its exit
// code (negative when it never started).
@(private="file")
_run_child :: proc(run_dir: string, command: []string, out_w, err_w: ^os.File) -> int {
    process, err := os.process_start({
        working_dir = run_dir,
        command     = command,
        stdout      = out_w,
        stderr      = err_w,
    })
    if err != nil {
        output_view_append_line(fmt.tprintf("run error: %v (%v)", err, command))
        return -1
    }
    state, wait_err := os.process_wait(process)
    if wait_err != nil {
        output_view_append_line(fmt.tprintf("--- wait error: %v ---", wait_err))
        return -1
    }
    return state.exit_code
}

_run_play_thread_proc :: proc(user_data: rawptr) {
    data := (^RunPlayData)(user_data)
    a := data.alloc
    run_dir := data.run_dir
    build_command := data.build_command
    run_command := data.run_command
    free(data, a)
    defer delete(run_dir, a)
    defer _delete_command(build_command, a)
    defer _delete_command(run_command, a)
    // Every exit path clears the phase, including the pipe failures below.
    defer sync.atomic_store(&_play_phase, Play_Phase.Idle)

    // The config binary is a build artifact of this one launch, so it is removed
    // at both ends: before the build so a crashed editor can never leave one
    // behind, and after the run so builds/ does not collect one per config
    // forever. Removing it first also means a build that reports success without
    // writing its output fails loudly at spawn instead of silently re-running the
    // previous binary. run_command[0] is that path.
    config_exe := run_command[0] if len(run_command) > 0 else ""
    if config_exe != "" do os.remove(config_exe)
    defer if config_exe != "" do os.remove(config_exe)

    stdout_r, stdout_w, stdout_err := os.pipe()
    if stdout_err != nil {
        output_view_append_line("Failed to create stdout pipe")
        return
    }
    defer os.close(stdout_r)

    stderr_r, stderr_w, stderr_err := os.pipe()
    if stderr_err != nil {
        os.close(stdout_w)
        output_view_append_line("Failed to create stderr pipe")
        return
    }
    defer os.close(stderr_r)

    // BOTH streams drain on their own threads, for the whole session and across
    // both children. Two reasons, and each alone would force it:
    //   - waiting on a child while nothing reads its pipe deadlocks the moment
    //     the child fills the buffer, and an `odin build` error page easily does.
    //   - alternating BLOCKING reads on one thread starve stdout whenever stderr
    //     is silent, which used to make app logs arrive in late bursts.
    // output_view_append is mutex-guarded and log.intake_remote is queued, so
    // both readers are safe off the main thread.
    stderr_thread := thread.create_and_start_with_poly_data(stderr_r, proc(fd: ^os.File) {
        buf: [4096]byte
        for {
            n, read_err := os.read(fd, buf[:])
            if n > 0 {
                output_view_append(nil, buf[:n])
            }
            if read_err != nil || n == 0 do return
        }
    })

    // stdout is consumed line-wise: the app's mh_log prints a machine-tagged
    // format that routes into the editor console, untagged lines go to Output.
    stdout_thread := thread.create_and_start_with_poly_data(stdout_r, proc(fd: ^os.File) {
        linebuf := make([dynamic]byte)
        defer delete(linebuf)
        buf: [4096]byte
        for {
            n, read_err := os.read(fd, buf[:])
            if n > 0 {
                _play_consume_stdout(&linebuf, buf[:n])
            }
            if read_err != nil || n == 0 {
                if len(linebuf) > 0 {
                    _play_dispatch_line(string(linebuf[:]))
                }
                return
            }
        }
    })

    // Compile the run config, then run it. A config that fails to compile never
    // launches, and its diagnostics are already in the console by then.
    //
    // The config itself builds the game before launching it, so Running covers
    // that second compile too — the editor cannot see where one ends and the
    // other begins without the config reporting it.
    code := _run_child(run_dir, build_command, stdout_w, stderr_w)
    build_ok := code == 0
    if build_ok {
        sync.atomic_store(&_play_phase, Play_Phase.Running)
        code = _run_child(run_dir, run_command, stdout_w, stderr_w)
    }

    // Dropping the parent's write ends is what gives the readers EOF. Join
    // before reporting so the exit line lands after the output it describes.
    os.close(stdout_w)
    os.close(stderr_w)
    if stdout_thread != nil {
        thread.join(stdout_thread)
        thread.destroy(stdout_thread)
    }
    if stderr_thread != nil {
        thread.join(stderr_thread)
        thread.destroy(stderr_thread)
    }

    if build_ok {
        output_view_append_line(fmt.tprintf("--- exit code %d ---", code))
    } else {
        output_view_append_line(fmt.tprintf("--- run config failed to build (exit code %d) ---", code))
    }
}

// Append a stdout chunk and dispatch every complete line in the buffer.
_play_consume_stdout :: proc(linebuf: ^[dynamic]byte, chunk: []byte) {
    append(linebuf, ..chunk)
    for {
        nl := -1
        for b, i in linebuf {
            if b == '\n' {
                nl = i
                break
            }
        }
        if nl < 0 do break
        _play_dispatch_line(string(linebuf[:nl]))
        remove_range(linebuf, 0, nl + 1)
    }
}

// Tagged mh_log lines become console entries (via the thread-safe intake
// queue); everything else goes to the Output view.
_play_dispatch_line :: proc(line: string) {
    l := line
    if len(l) > 0 && l[len(l)-1] == '\r' {
        l = l[:len(l)-1]
    }
    if strings.has_prefix(l, log.STDOUT_TAG) {
        rest := l[len(log.STDOUT_TAG):]
        parts := strings.split_n(rest, "|", 7, context.temp_allocator)
        if len(parts) == 7 {
            lvl_i, lvl_ok := strconv.parse_int(parts[0])
            t_ns, _ := strconv.parse_i64(parts[1]) // 0 on failure -> intake stamps now()
            line_no, line_ok := strconv.parse_int(parts[3])
            if lvl_ok && line_ok && lvl_i >= 0 && lvl_i <= int(max(log.Level)) {
                // Stack field: frames joined by STACK_SEP; empty when the app
                // wasn't a debug build.
                frames: []string
                if parts[5] != "" {
                    frames = strings.split(parts[5], log.STACK_SEP, context.temp_allocator)
                }
                log.intake_remote(log.Level(lvl_i), time.Time{_nsec = t_ns}, parts[2], line_no, parts[4], parts[6], frames)
                return
            }
        }
    }
    output_view_append_line(l)
}

// Compiles the given run config (an Odin program, see Run_Config) and runs it —
// bare for Play (the config's own scene), with the live-scene snapshot path for
// the Build button. `id` only names the config binary, so two packages can each
// ship a run.odin without colliding.
// Toolbar modifier state at click time, forwarded to the config as flags the
// rc procs honor (runconfig.FLAGS): plain = build, export, run the export.
Run_Mode :: enum {
	Build_And_Run,
	Dev,        // Alt: build, run against the live library catalog, no export
	Run_Only,   // Shift: run the last build, no compile, no staging
	Build_Only, // Alt+Shift: build and stage, no run
}

_run_mode_from_modifiers :: proc() -> Run_Mode {
	io := im.GetIO()
	if io.KeyAlt && io.KeyShift do return .Build_Only
	if io.KeyAlt do return .Dev
	if io.KeyShift do return .Run_Only
	return .Build_And_Run
}

run_app_play :: proc(id: string, source: string, with_current_scene := false, mode := Run_Mode.Build_And_Run) {
    if _play_thread != nil && !thread.is_done(_play_thread) {
        return
    }
    if _play_thread != nil {
        thread.join(_play_thread)
        thread.destroy(_play_thread)
        _play_thread = nil
    }
    console_clear_on_play()
    // Configs run from the REPO ROOT (parent of the editor's normalized
    // moonhug/ cwd) — the one canonical build cwd. The app normalizes its own
    // runtime cwd back to moonhug/.
    cwd, _ := os.get_working_directory(context.temp_allocator)
    repo_root := filepath.dir(cwd) // slice into the temp cwd string

    // Config binaries sit in builds/ beside the game binaries they produce.
    // Always rebuilt, so there is no staleness to invalidate and nothing to
    // clean up. -file compiles the single config source, -ignore-unknown-
    // attributes lets a config import engine or editor packages.
    safe_id, _ := strings.replace_all(id, "/", "_", context.temp_allocator)
    config_exe := fmt.tprintf("builds/run_config_%s%s", safe_id, runconfig.EXE_SUFFIX)
    build_parts := []string{
        "odin", "build", source, "-file",
        "-ignore-unknown-attributes", "-collection:moonhug=moonhug",
        fmt.tprintf("-out:%s", config_exe),
    }

    // The binary to RUN must be an absolute path. os.process_start resolves
    // command[0] in the PARENT, before the child chdir's to working_dir: a bare
    // name goes through PATH, but anything containing a '/' is opened relative to
    // the EDITOR's cwd (moonhug/), not the repo root. Only `odin` and `sh` got
    // away with being relative, because PATH resolved them.
    config_exe_abs, _ := filepath.join({repo_root, config_exe}, context.temp_allocator)

    // The Play button passes NOTHING: a run config works with its own pinned
    // scene, so its build reproduces bare launches exactly. The Build button
    // passes the LIVE scene state (a snapshot of the in-memory scene written
    // outside assets/, so refresh never mints a guid for it) — unsaved edits
    // run as-is, like Unity entering play mode with a dirty scene. The rc run
    // procs forward it to the game; nested prefabs still resolve by guid.
    run_parts := make([dynamic]string, context.temp_allocator)
    append(&run_parts, config_exe_abs)
    if with_current_scene {
        if scene := engine.sm_scene_get_active(); scene != nil {
            play_path := scene.path
            if snapshot, sok := engine.scene_serialize(scene); sok {
                defer delete(snapshot)
                os.make_directory("library") // library/ is gitignored; fresh clones lack it
                os.make_directory("library/state_cache")
                if os.write_entire_file(_PLAY_SCENE_SNAPSHOT_PATH, snapshot) == nil {
                    play_path = _PLAY_SCENE_SNAPSHOT_PATH
                }
            }
            if len(play_path) > 0 do append(&run_parts, play_path)
        }
    }
    switch mode {
    case .Dev:        append(&run_parts, "--dev")
    case .Build_Only: append(&run_parts, "--build-only")
    case .Run_Only:   append(&run_parts, "--run-only")
    case .Build_And_Run:
    }

    pa := runtime.default_allocator()
    data, derr := new(RunPlayData, pa)
    if derr != nil {
        return
    }
    data.alloc = pa
    rd, cerr := strings.clone(repo_root, pa)
    if cerr != nil {
        free(data, pa)
        return
    }
    data.run_dir = rd
    data.build_command = _clone_command(build_parts, pa)
    data.run_command = _clone_command(run_parts[:], pa)
    if data.build_command == nil || data.run_command == nil {
        _destroy_run_play_data(data)
        return
    }

    // Set before the spawn, not inside the thread, so there is no frame where the
    // thread is alive but the toolbar still reads Idle.
    sync.atomic_store(&_play_phase, Play_Phase.Compiling)
    _play_thread = thread.create_and_start_with_data(data, _run_play_thread_proc)
    if _play_thread == nil {
        sync.atomic_store(&_play_phase, Play_Phase.Idle)
        _destroy_run_play_data(data)
    }
}

join_play_thread :: proc() {
    if _play_thread != nil {
        thread.join(_play_thread)
        thread.destroy(_play_thread)
        _play_thread = nil
    }
}
