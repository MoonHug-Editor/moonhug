package editor

import "core:strings"
import "core:fmt"
import "core:os"
import "core:thread"
import im "../../external/odin-imgui"

TOOLBAR_HEIGHT :: 28

_play_thread: ^thread.Thread

draw_tool_bar :: proc() {
    vp := im.GetMainViewport()
    im.SetNextWindowPos(vp.WorkPos, {}, {0, 0})
    im.SetNextWindowSize(im.Vec2{vp.WorkSize.x, f32(TOOLBAR_HEIGHT)}, {})
    if !im.Begin("##ToolBar", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoDocking}) do return
    defer im.End()
    button_play_text:cstring= ">"
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
        im.SetTooltip("Run game (odin run app)")
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
    run_dir: string,
    command: []string,
}

_run_play_thread_proc :: proc(user_data: rawptr) {
    data := (^RunPlayData)(user_data)
    run_dir := data.run_dir
    command := data.command
    free(data)
    defer delete(run_dir)
    defer delete(command)

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

    buf: [4096]byte
    stdout_done := false
    stderr_done := false

    for !stdout_done || !stderr_done {
        if !stdout_done {
            n, read_err := os.read(stdout_r, buf[:])
            if n > 0 {
                output_view_append(buf[:n], nil)
            }
            if read_err != nil || n == 0 {
                stdout_done = true
            }
        }

        if !stderr_done {
            n, read_err := os.read(stderr_r, buf[:])
            if n > 0 {
                output_view_append(nil, buf[:n])
            }
            if read_err != nil || n == 0 {
                stderr_done = true
            }
        }
    }

    state, wait_err := os.process_wait(process)
    if wait_err != nil {
        output_view_append_line(fmt.tprintf("--- wait error: %v ---", wait_err))
    } else {
        output_view_append_line(fmt.tprintf("--- exit code %d ---", state.exit_code))
    }
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
    cwd, _ := os.get_working_directory(context.temp_allocator)
    data := new(RunPlayData)
    data.run_dir = strings.clone(cwd)
    data.command = make([]string, 4)
    data.command[0] = "odin"
    data.command[1] = "run"
    data.command[2] = "app"
    data.command[3] = "-ignore-unknown-attributes"
    _play_thread = thread.create_and_start_with_data(data, _run_play_thread_proc)
}

join_play_thread :: proc() {
    if _play_thread != nil {
        thread.join(_play_thread)
        thread.destroy(_play_thread)
        _play_thread = nil
    }
}

