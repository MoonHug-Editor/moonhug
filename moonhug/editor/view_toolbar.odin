package editor

import "base:runtime"
import "core:strings"
import "core:strconv"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:thread"
import "core:time"
import im "../../external/odin-imgui"
import "../engine"
import "../engine/log"

TOOLBAR_HEIGHT :: 28

// Live-state play snapshot lives in library/ (never assets/): the AssetDB
// walk must not see it, or refresh would mint a guid for a transient file.
_PLAY_SCENE_SNAPSHOT_PATH :: "library/play_scene_snapshot.scene"

_play_thread: ^thread.Thread

draw_tool_bar :: proc() {
    vp := im.GetMainViewport()
    im.SetNextWindowPos(vp.WorkPos, {}, {0, 0})
    im.SetNextWindowSize(im.Vec2{vp.WorkSize.x, f32(TOOLBAR_HEIGHT)}, {})
    if !im.Begin("##ToolBar", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoDocking}) do return
    defer im.End()
    button_play_text: cstring = ICON_MD_PLAY_ARROW
    avail := im.GetContentRegionAvail()
    btn_size := im.CalcTextSize(button_play_text, nil, false, -1)
    style := im.GetStyle()
    btn_size.x += style.FramePadding.x * 2
    btn_size.y += style.FramePadding.y * 2
    im.SetCursorPosX((avail.x - btn_size.x) * 0.5)
    if im.Button(button_play_text) {
        run_app_play()
    }
    if _play_thread != nil && !thread.is_done(_play_thread) {
        im.SameLine()
        im.TextDisabled("(running)")
    }
    if im.IsItemHovered({}) {
        im.SetTooltip("Run game with current scene state (odin run app)")
    }

    // Dockspace in a host window below the toolbar (so toolbar is fixed under menubar, not floating)
    dockspace_pos := im.Vec2{vp.WorkPos.x, vp.WorkPos.y + f32(TOOLBAR_HEIGHT)}
    dockspace_size := im.Vec2{vp.WorkSize.x, vp.WorkSize.y - f32(TOOLBAR_HEIGHT)}
    im.SetNextWindowPos(dockspace_pos, {}, {0, 0})
    im.SetNextWindowSize(dockspace_size, {})
    if im.Begin("##DockSpaceHost", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoCollapse}) {
        dockspace_id := im.GetID("DockSpace")
        im.DockSpace(dockspace_id, im.Vec2{0, 0}, {}, nil)
        im.End()
    }
}

RunPlayData :: struct {
    alloc:   mem.Allocator,
    run_dir: string,
    command: []string,
}

_destroy_run_play_data :: proc(data: ^RunPlayData) {
    a := data.alloc
    delete(data.run_dir, a)
    delete(data.command, a)
    free(data, a)
}

_run_play_thread_proc :: proc(user_data: rawptr) {
    data := (^RunPlayData)(user_data)
    a := data.alloc
    run_dir := data.run_dir
    command := data.command
    free(data, a)
    defer delete(run_dir, a)
    defer delete(command, a)

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

    desc := os.Process_Desc{
        working_dir = run_dir,
        command     = command,
        env         = nil,
        stdout      = stdout_w,
        stderr      = stderr_w,
        stdin       = nil,
    }

    process, err := os.process_start(desc)
    if err != nil {
        os.close(stdout_w)
        os.close(stderr_w)
        output_view_append_line(fmt.tprintf("run app error: %v", err))
        return
    }

    os.close(stdout_w)
    os.close(stderr_w)

    // stderr drains on its own thread: alternating BLOCKING reads on one
    // thread starve stdout whenever stderr is silent, so app logs used to
    // arrive in late bursts. output_view_append is mutex-guarded.
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

    // stdout is consumed line-wise on this thread: the app's mh_log prints a
    // machine-tagged format that routes into the editor console; untagged
    // lines go to the Output view as before.
    buf: [4096]byte
    stdout_linebuf := make([dynamic]byte)
    defer delete(stdout_linebuf)

    for {
        n, read_err := os.read(stdout_r, buf[:])
        if n > 0 {
            _play_consume_stdout(&stdout_linebuf, buf[:n])
        }
        if read_err != nil || n == 0 {
            if len(stdout_linebuf) > 0 {
                _play_dispatch_line(string(stdout_linebuf[:]))
                clear(&stdout_linebuf)
            }
            break
        }
    }

    if stderr_thread != nil {
        thread.join(stderr_thread)
        thread.destroy(stderr_thread)
    }

    state, wait_err := os.process_wait(process)
    if wait_err != nil {
        output_view_append_line(fmt.tprintf("--- wait error: %v ---", wait_err))
    } else {
        output_view_append_line(fmt.tprintf("--- exit code %d ---", state.exit_code))
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

run_app_play :: proc() {
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
    cwd, _ := os.get_working_directory(context.temp_allocator)
    pa := runtime.default_allocator()
    data, derr := new(RunPlayData, pa)
    if derr != nil {
        return
    }

    data.alloc = pa
    rd, cerr := strings.clone(cwd, pa)
    if cerr != nil {
        free(data, pa)
        return
    }

    data.run_dir = rd
    cmd, merr := make([]string, 5, pa)
    if merr != nil {
        delete(data.run_dir, pa)
        free(data, pa)
        return
    }

    data.command = cmd
    data.command[0] = "odin"
    data.command[1] = "run"
    data.command[2] = "app"
    data.command[3] = "-ignore-unknown-attributes"
    // Debug build so the app captures call stacks for its console log lines
    // (capture is ODIN_DEBUG-gated in the app process).
    data.command[4] = "-debug"

    // Pass the editor's active scene to the app (args after "--" reach the
    // program); without one the app falls back to its default scene. The app
    // gets the LIVE scene state: a snapshot of the in-memory scene written
    // outside assets/ (so refresh never mints a guid for it) — unsaved edits
    // play as-is, like Unity entering play mode with a dirty scene. Nested
    // prefabs still resolve by guid from their on-disk files.
    if scene := engine.sm_scene_get_active(); scene != nil {
        play_path := scene.path
        if snapshot, sok := engine.scene_serialize(scene); sok {
            defer delete(snapshot)
            os.make_directory("library") // library/ is gitignored; fresh clones lack it
            if os.write_entire_file(_PLAY_SCENE_SNAPSHOT_PATH, snapshot) == nil {
                play_path = _PLAY_SCENE_SNAPSHOT_PATH
            }
        }
        if len(play_path) > 0 {
            with_scene, aerr := make([]string, 7, pa)
            if aerr == nil {
                copy(with_scene, data.command)
                with_scene[5] = "--"
                with_scene[6], _ = strings.clone(play_path, pa)
                delete(data.command, pa)
                data.command = with_scene
            }
        }
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
