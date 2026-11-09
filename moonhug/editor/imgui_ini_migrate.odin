package editor

// imgui saves a window's placement under the text after "###" in its title:
// the built-in windows keep their old names there, so their entries carry over
// as they are. Plugin windows changed from their title to their id when the
// titles gained icons ("<icon> Sequencer###sequencer"), so an imgui.ini from
// before names them by title. Renaming those entries in place, before imgui
// reads the file at its first frame, keeps the user's layout: the dock ids
// and positions carry over untouched. An entry already saved under the id
// gives way to the old one, which is the user's placement. Idempotent.
//
// The same pass drops the entries of window copies that are gone for good. A
// copy's key (`<id>/<n>`) is never handed out again (window.open_another), so
// imgui would keep the dock place of every copy ever opened. At startup a copy
// that the saved open windows do not name cannot come back: the list of closed
// windows did not outlive the last session, and a window in a workspace frame
// has no entry to lose, since it draws inside its frame.

import "core:os"
import "core:strings"
import wnd "window"

@(private = "file") _IMGUI_INI :: "imgui.ini"

migrate_imgui_ini :: proc() {
	data, err := os.read_entire_file(_IMGUI_INI, context.temp_allocator)
	if err != nil do return
	text := string(data)

	// The ini is blocks: a "[Kind][Name]" header, its lines, a blank line.
	Block :: struct {
		header: string,
		body:   string, // the lines after the header, up to and excluding the blank line
	}
	blocks := make([dynamic]Block, context.temp_allocator)
	cur: Block
	body := strings.builder_make(context.temp_allocator)
	flush :: proc(blocks: ^[dynamic]Block, cur: ^Block, body: ^strings.Builder) {
		if cur.header == "" && strings.builder_len(body^) == 0 do return
		cur.body = strings.clone(strings.to_string(body^), context.temp_allocator)
		append(blocks, cur^)
		cur^ = {}
		strings.builder_reset(body)
	}
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "[") {
			flush(&blocks, &cur, &body)
			cur.header = line
			continue
		}
		if line == "" {
			flush(&blocks, &cur, &body)
			continue
		}
		strings.write_string(&body, line)
		strings.write_byte(&body, '\n')
	}
	flush(&blocks, &cur, &body)

	// Title-named plugin window blocks become id-named; a block already saved
	// under the id, which comes later in the file, gives way to them.
	keep_index := make(map[string]int, context.temp_allocator) // id -> the block that stays
	migrated := false
	for &b, i in blocks {
		if name, ok := _window_name(b.header); ok {
			if id, old := _migrated_id(name); old {
				b.header = strings.concatenate({"[Window][", id, "]"}, context.temp_allocator)
				if id not_in keep_index do keep_index[id] = i
				migrated = true
			}
		}
	}
	// Copies gone for good. Only with a saved list of open windows to tell.
	gone := make([]bool, len(blocks), context.temp_allocator)
	pruned := false
	if editor_settings.has_window_state {
		for b, i in blocks {
			name, ok := _window_name(b.header)
			if !ok || !_is_copy_key(name) do continue
			open := false
			for k in editor_settings.open_window_ids do if k == name do open = true
			if open do continue
			gone[i] = true
			pruned = true
		}
	}
	if !migrated && !pruned do return

	out := strings.builder_make(0, len(text) + 64, context.temp_allocator)
	for b, i in blocks {
		if gone[i] do continue
		if name, ok := _window_name(b.header); ok {
			if first, has := keep_index[name]; has && first != i do continue
		}
		strings.write_string(&out, b.header)
		strings.write_byte(&out, '\n')
		strings.write_string(&out, b.body)
		strings.write_byte(&out, '\n')
	}
	_ = os.write_entire_file(_IMGUI_INI, transmute([]u8)strings.to_string(out))
}

// Whether `name` is the key of a numbered window copy: `<id>/<digits>`.
@(private = "file")
_is_copy_key :: proc(name: string) -> bool {
	slash := strings.last_index_byte(name, '/')
	if slash <= 0 || slash == len(name) - 1 do return false
	for c in name[slash + 1:] do if c < '0' || c > '9' do return false
	return true
}

@(private = "file")
_window_name :: proc(header: string) -> (string, bool) {
	if strings.has_prefix(header, "[Window][") && strings.has_suffix(header, "]") {
		return header[len("[Window]["):len(header) - 1], true
	}
	return "", false
}

// A plugin window's title, when it differs from its id.
@(private = "file")
_migrated_id :: proc(name: string) -> (string, bool) {
	for w in wnd.registered() do if name == w.title && w.title != w.id do return w.id, true
	return "", false
}
