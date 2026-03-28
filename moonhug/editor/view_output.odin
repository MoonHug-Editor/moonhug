package editor

import "core:strings"
import "core:sync"
import im "../../external/odin-imgui"

MAX_OUTPUT_LINES :: 2000

_output_lines: [dynamic]string
_output_mutex: sync.Mutex
_output_last_count: int

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
	_output_last_count = 0
}

ordered_remove :: proc(s: ^[dynamic]string, index: int) {
	if index < 0 || index >= len(s) do return
	for i in index ..< len(s) - 1 {
		s[i] = s[i + 1]
	}
	pop(s)
}

draw_output_view :: proc() {
	if !im.Begin("Output", nil, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	if im.Button("Clear") {
		output_view_clear()
	}
	im.SameLine()
	im.Text("Last run stdout/stderr (max %d lines)", MAX_OUTPUT_LINES)
	im.Separator()

	im.BeginChild("OutputScroll", im.Vec2{0, 0}, {.Borders})
	defer im.EndChild()

	sync.mutex_lock(&_output_mutex)
	n := len(_output_lines)
	for line in _output_lines {
		cstr := strings.clone_to_cstring(line)
		defer delete(cstr)
		im.TextUnformatted(cstr)
	}
	if n > _output_last_count && n > 0 {
		im.SetScrollHereY(1)
	}
	_output_last_count = n
	sync.mutex_unlock(&_output_mutex)
}
