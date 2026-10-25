package editor

import "core:strings"
import "core:sync"
import im "moonhug:external/odin-imgui"
import wnd "moonhug:editor/window"

MAX_OUTPUT_LINES :: 2000

_output_lines: [dynamic]string
_output_mutex: sync.Mutex

// One Output copy's own state.
@(private = "file")
_Output_View :: struct {
	// Off means the view stays where you scrolled it while a build keeps
	// writing, which is the only way to read an error that has scrolled past.
	follow_tail: bool,
	last_count:  int, // lines shown last frame: more means new output
}

output_view_append :: proc(stdout, stderr: []byte) {
	if len(stdout) == 0 && len(stderr) == 0 do return
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)

	append_lines :: proc(lines: ^[dynamic]string, data: []byte, prefix: string) {
		if len(data) == 0 do return
		s := transmute(string)(data)
		for {
			idx := strings.index_byte(s, '\n')
			if idx >= 0 {
				line := s[:idx]
				if prefix != "" {
					line = strings.concatenate({prefix, line})
				}
				append(lines, strings.clone(line))
				s = s[idx + 1:]
			} else {
				if len(s) > 0 {
					if prefix != "" {
						s = strings.concatenate({prefix, s})
					}
					append(lines, strings.clone(s))
				}
				break
			}
		}
	}

	append_lines(&_output_lines, stdout, "")
	append_lines(&_output_lines, stderr, "[stderr] ")

	for len(_output_lines) > MAX_OUTPUT_LINES {
		delete(_output_lines[0])
		ordered_remove(&_output_lines, 0)
	}
}

output_view_append_line :: proc(line: string) {
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)
	append(&_output_lines, strings.clone(line))
	for len(_output_lines) > MAX_OUTPUT_LINES {
		delete(_output_lines[0])
		ordered_remove(&_output_lines, 0)
	}
}

output_view_clear :: proc() {
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)
	for line in _output_lines {
		delete(line)
	}
	clear(&_output_lines)
}

@(editor_window={id="Output", title="Output", icon="RECEIPT_LONG"})
output_view_draw :: proc(w: ^wnd.Window) {
	ov := wnd.state(w, _Output_View{follow_tail = true})
	if im.Button("Clear") {
		output_view_clear()
	}
	im.SameLine()
	filter_toggle_button("Follow", &ov.follow_tail)
	im.SameLine()
	im.Text("Last run stdout/stderr (max %d lines)", MAX_OUTPUT_LINES)
	im.Separator()

	// Read-only multiline input: real text selection + copy (an error line
	// from a build failure must be selectable). Lines are joined per frame —
	// bounded by MAX_OUTPUT_LINES, temp-allocated.
	sync.mutex_lock(&_output_mutex)
	n := len(_output_lines)
	joined := strings.join(_output_lines[:], "\n", context.temp_allocator)
	sync.mutex_unlock(&_output_mutex)

	if ov.follow_tail && n > ov.last_count && n > 0 {
		// New output: pin the input's internal child (the NEXT window imgui
		// creates) to the bottom. x = -1 leaves horizontal scroll alone.
		im.SetNextWindowScroll(im.Vec2{-1, max(f32)})
	}
	ov.last_count = n
	buf := strings.clone_to_cstring(joined, context.temp_allocator)
	im.InputTextMultiline("##output_text", buf, len(joined) + 1, im.Vec2{-1, -1}, {.ReadOnly})
}
