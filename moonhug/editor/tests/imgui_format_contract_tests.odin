package editor_tests

// imgui's text procs that take a printf format (Text, TextColored,
// TextDisabled, TextWrapped, BulletText, LabelText, SetTooltip,
// SetItemTooltip) read varargs for every `%` in it. Text that comes from data,
// a log line or an asset name, is not a format: a `%s` in it reads an
// argument nobody passed. The rule: the format is a string literal. Runtime
// text goes to the Unformatted proc of the same name, or after a literal
// "%s".

import "core:os"
import "core:strings"
import "core:testing"

_IMGUI_FORMAT_ROOTS := []string{"moonhug/editor", "moonhug/libs", "plugins"}

// The procs, and which argument is the format.
_IMGUI_FORMAT_PROCS := []struct{ name: string, format_arg: int }{
	{"Text(", 0},
	{"TextDisabled(", 0},
	{"TextWrapped(", 0},
	{"BulletText(", 0},
	{"SetTooltip(", 0},
	{"SetItemTooltip(", 0},
	{"TextColored(", 1},
	{"LabelText(", 1},
}

@(test)
test_imgui_format_is_a_literal :: proc(t: ^testing.T) {
	seen := 0
	for root in _IMGUI_FORMAT_ROOTS {
		files := make([dynamic]string, context.temp_allocator)
		_collect_odin_files(root, &files)
		for path in files {
			if strings.has_suffix(path, "_generated.odin") do continue
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if rerr != nil do continue
			seen += 1
			text := string(data)
			n := 0
			for raw in strings.split_lines_iterator(&text) {
				n += 1
				line := strings.trim_space(raw)
				if strings.has_prefix(line, "//") do continue
				if name, bad := _dynamic_imgui_format(line); bad {
					testing.expectf(t, false, "%s:%d: im.%s) takes runtime text as its printf format. Use the Unformatted proc, or pass it after a literal \"%%s\"", path, n, name)
				}
			}
		}
	}
	testing.expect(t, seen > 100, "the walk should see the editor's sources")
}

// The format proc `line` calls with a format that is not a string literal.
_dynamic_imgui_format :: proc(line: string) -> (name: string, bad: bool) {
	for p in _IMGUI_FORMAT_PROCS {
		call := strings.concatenate({"im.", p.name}, context.temp_allocator)
		rest := line
		for {
			at := strings.index(rest, call)
			if at < 0 do break
			rest = rest[at + len(call):]
			arg := strings.trim_space(_call_arg(rest, p.format_arg))
			// An argument list that goes on to the next line is not judged.
			if arg != "" && arg[0] != '"' && arg[0] != '`' do return p.name, true
		}
	}
	return "", false
}

// Argument `index` of the argument list `args` starts in, "" when the line
// ends before it.
_call_arg :: proc(args: string, index: int) -> string {
	depth, at, start := 0, 0, 0
	in_string := false
	for c, i in args {
		switch {
		case in_string:
			if c == '"' && (i == 0 || args[i - 1] != '\\') do in_string = false
		case c == '"':
			in_string = true
		case c == '(' || c == '{' || c == '[':
			depth += 1
		case c == ')' || c == '}' || c == ']':
			if depth == 0 do return at == index ? args[start:i] : ""
			depth -= 1
		case c == ',' && depth == 0:
			if at == index do return args[start:i]
			at += 1
			start = i + 1
		}
	}
	return at == index ? args[start:] : ""
}

// The scan itself: what it flags and what it lets through.
@(test)
test_imgui_format_scan_tells_runtime_text :: proc(t: ^testing.T) {
	bad := []string{
		`im.Text(drag_label)`,
		`im.TextColored(_console_level_color(entry.level), cmsg)`,
		`im.TextColored({1, 0.7, 0.2, 1}, icons.ICON_MD_WARNING)`,
		`if x do im.TextDisabled(fmt.ctprintf("%s has none", name))`,
		`im.SetTooltip(tip)`,
	}
	good := []string{
		`im.Text("Size: %d", i32(n))`,
		`im.TextColored({1, 0, 0, 1}, "%s", cmsg)`,
		`im.TextDisabled("(empty)")`,
		`im.TextUnformatted(drag_label)`,
		`im.TextColoredUnformatted(color, cmsg)`,
		`im.TextColored(color,`,
	}
	for l in bad {
		_, flagged := _dynamic_imgui_format(l)
		testing.expectf(t, flagged, "should be flagged: %s", l)
	}
	for l in good {
		_, flagged := _dynamic_imgui_format(l)
		testing.expectf(t, !flagged, "should pass: %s", l)
	}
}
