package editor

import "base:runtime"
import "core:strings"
import "core:strconv"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:thread"
import "core:time"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/runconfig"
import "../engine"
import "../engine/log"

TOOLBAR_HEIGHT :: 28

// Live-state play snapshot lives in library/ (never assets/): the AssetDB
// walk must not see it, or refresh would mint a guid for a transient file.
_PLAY_SCENE_SNAPSHOT_PATH :: "library/play_scene_snapshot.scene"

_play_thread: ^thread.Thread

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
        if pkg.type != .Directory do continue
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

draw_tool_bar :: proc() {
    vp := im.GetMainViewport()
    im.SetNextWindowPos(vp.WorkPos, {}, {0, 0})
    im.SetNextWindowSize(im.Vec2{vp.WorkSize.x, f32(TOOLBAR_HEIGHT)}, {})
    if !im.Begin("##ToolBar", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoDocking}) do return
    defer im.End()

    if len(_run_configs) == 0 do _scan_run_configs()
    sel := _selected_run_config()

    // Play button + run-config dropdown, centered together. The dropdown reads
    // out the selected config rather than being an icon-only arrow: which config
    // Play will run is worth seeing without opening anything.
    button_play_text: cstring = ICON_MD_PLAY_ARROW
    avail := im.GetContentRegionAvail()
    style := im.GetStyle()
    btn_size := im.CalcTextSize(button_play_text, nil, false, -1)
    btn_size.x += style.FramePadding.x * 2
    btn_size.y += style.FramePadding.y * 2

    NO_CONFIGS :: cstring("No run configs")
    preview := NO_CONFIGS
    if sel != nil do preview = sel.label

    // Sized to the WIDEST config, not the selected one, so switching configs
    // never shifts the toolbar. GetFrameHeight is the combo's square arrow box.
    combo_w := im.CalcTextSize(NO_CONFIGS, nil, false, -1).x
    for &rc in _run_configs {
        combo_w = max(combo_w, im.CalcTextSize(rc.label, nil, false, -1).x)
    }
    combo_w += style.FramePadding.x * 2 + im.GetFrameHeight()

    total_w := btn_size.x + style.ItemSpacing.x + combo_w
    im.SetCursorPosX((avail.x - total_w) * 0.5)

    if im.Button(button_play_text) && sel != nil {
        run_app_play(sel.id, sel.source)
    }
    if im.IsItemHovered({}) {
        if sel != nil {
            im.SetTooltip(fmt.ctprintf("Run game with current scene state (%s)", sel.label))
        } else {
            im.SetTooltip("No run configs found (packages/*/run_configs/*.odin)")
        }
    }

    im.SameLine()
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
    if im.IsItemHovered({}) {
        im.SetTooltip("Run configuration")
    }

    if _play_thread != nil && !thread.is_done(_play_thread) {
        im.SameLine()
        im.TextDisabled("(running)")
    }
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
    code := _run_child(run_dir, build_command, stdout_w, stderr_w)
    build_ok := code == 0
    if build_ok {
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

// Compiles the given run config (an Odin program, see Run_Config) and runs it
// with the live-scene snapshot path as its argument. `id` only names the config
// binary, so two packages can each ship a run.odin without colliding.
run_app_play :: proc(id: string, source: string) {
    if _play_thread != nil && !thread.is_done(_play_thread) {
        return
    }
    if _play_thread != nil {
        thread.join(_play_thread)
        thread.destroy(_play_thread)
        _play_thread = nil
    }
    if _console_clear_on_play {
        log.clear()
        _console_last_count = 0
    }
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

    // Pass the editor's active scene to the config, which forwards it to the
    // game; without one the app falls back to its default scene. The app gets
    // the LIVE scene state: a snapshot of the in-memory scene written outside
    // assets/ (so refresh never mints a guid for it) — unsaved edits play as-is,
    // like Unity entering play mode with a dirty scene. Nested prefabs still
    // resolve by guid from their on-disk files.
    run_parts := make([dynamic]string, context.temp_allocator)
    append(&run_parts, config_exe_abs)
    if scene := engine.sm_scene_get_active(); scene != nil {
        play_path := scene.path
        if snapshot, sok := engine.scene_serialize(scene); sok {
            defer delete(snapshot)
            os.make_directory("library") // library/ is gitignored; fresh clones lack it
            if os.write_entire_file(_PLAY_SCENE_SNAPSHOT_PATH, snapshot) == nil {
                play_path = _PLAY_SCENE_SNAPSHOT_PATH
            }
        }
        if len(play_path) > 0 do append(&run_parts, play_path)
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

    _play_thread = thread.create_and_start_with_data(data, _run_play_thread_proc)
    if _play_thread == nil {
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
