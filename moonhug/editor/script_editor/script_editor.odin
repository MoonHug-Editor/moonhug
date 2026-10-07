package script_editor

// Opens source files for Edit Script in a component's menu. The file opens
// with the app the OS associates with it. A command in the External Tools
// setting opens it in a chosen editor instead, at the declaration's line.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:thread"
import "core:time"
import "moonhug:host/assets"
import "moonhug:host/log"
import core "moonhug:host/core"

External_Tools :: struct {
	// Optional. The command that opens a file at a line, split into words on
	// spaces, with {file} and {line} replaced in each word:
	// `zed {file}:{line}`, `code -g {file}:{line}`, `clion --line {line} {file}`.
	// Empty opens the file with the app the OS associates with it.
	script_editor: string `decor:help(text="Optional. The command Edit Script runs to open a script at its line, with {file} and {line} filled in.\n - Empty opens the file with the app the OS associates with it, at the top.\n - Zed: /Applications/Zed.app/Contents/MacOS/cli {file}:{line}.\n - VS Code: code -g {file}:{line}.\n - CLion: clion --line {line} {file}.\n The program path cannot contain spaces.")`,
}

@(user_settings={name="External Tools", tab="External Tools"})
external_tools: External_Tools

// Whether open_type_source has a file to open for T.
has_type_source :: proc(T: typeid) -> bool {
	_, _, ok := core.type_source(T)
	return ok
}

// Opens the file that declares T, at the declaration. False when T has no
// recorded source or nothing could open the file. Every step is logged to the
// Console.
open_type_source :: proc(T: typeid) -> bool {
	path, line, ok := core.type_source(T)
	if !ok {
		log.warningf("[Edit Script] %v has no recorded source file", T)
		return false
	}
	abs := repo_path(path)
	if named, is_named := type_info_of(T).variant.(runtime.Type_Info_Named); is_named {
		if found := declaration_line(abs, named.name, line); found != line {
			log.infof("[Edit Script] %s moved from line %d to %d since this build", named.name, line, found)
			line = found
		}
	}
	return open_source(abs, line)
}

// A repo-relative path, such as a recorded type source, as an absolute path.
// The editor runs in moonhug/ and the tests at the repo root, so the root is
// found from the project directory rather than assumed to be the cwd.
repo_path :: proc(path: string) -> string {
	if filepath.is_abs(path) do return path
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return path
	project, ok := assets.project_root_find(cwd)
	if !ok do return path
	context.allocator = context.temp_allocator // filepath.dir takes no allocator
	joined, _ := filepath.join({filepath.dir(project), path})
	return joined
}

// Opens `path`, repo-relative or absolute, at `line` in the script editor,
// and logs what it runs to the Console.
open_source :: proc(path: string, line: int) -> bool {
	abs := repo_path(path)
	if !os.exists(abs) {
		log.errorf("[Edit Script] %s does not exist", abs)
		return false
	}
	command: []string
	editor: string
	if template := strings.trim_space(external_tools.script_editor); template != "" {
		command = script_editor_command(template, abs, line)
		editor = "the External Tools script_editor setting"
	} else {
		// Cloned where each literal is made, since a slice literal lives in
		// its block.
		when ODIN_OS == .Darwin {
			command = slice.clone([]string{"open", abs}, context.temp_allocator)
		} else when ODIN_OS == .Windows {
			command = slice.clone([]string{"cmd", "/C", "start", "", abs}, context.temp_allocator)
		} else {
			command = slice.clone([]string{"xdg-open", abs}, context.temp_allocator)
		}
		editor = "the app the OS opens it with (set External Tools > Script Editor in Settings to open it at the line)"
	}
	shown := strings.join(command, " ", context.temp_allocator)
	log.infof("[Edit Script] opening %s:%d with %s: %s", abs, line, editor, shown)

	// The launcher's error output goes to a file, read once it exits. A pipe
	// would stay open while an editor it started inherits it.
	errors, ferr := os.create_temp_file("", "moonhug_edit_script_*.txt")
	if ferr != nil {
		log.errorf("[Edit Script] cannot create a file for the launcher's errors: %v", ferr)
		return false
	}
	process, err := os.process_start({command = command, stderr = errors})
	if err != nil {
		log.errorf("[Edit Script] cannot start `%s`: %v", shown, err)
		os.close(errors)
		os.remove(os.name(errors))
		return false
	}
	// Editor launchers hand the file to the editor and exit. A thread waits
	// for that, so the child does not stay a zombie and no frame waits, and
	// reports a failure to the Console.
	thread.create_and_start_with_poly_data(_Launch{process = process, errors = errors, shown = strings.clone(shown, runtime.default_allocator())}, _wait_launch, self_cleanup = true)
	return true
}

@(private = "file")
_Launch :: struct {
	process: os.Process,
	errors:  ^os.File,
	shown:   string, // the command, on the default allocator, freed by _wait_launch
}

@(private = "file")
_wait_launch :: proc(l: _Launch) {
	context.allocator = runtime.default_allocator()
	defer delete(l.shown)
	path := strings.clone(os.name(l.errors))
	defer delete(path)
	defer os.remove(path)
	state, err := os.process_wait(l.process)
	os.close(l.errors)
	text: string
	if data, rerr := os.read_entire_file(path, context.allocator); rerr == nil {
		text = strings.trim_space(string(data))
		defer delete(data)
		text = strings.clone(text)
	}
	defer delete(text)
	switch {
	case err != nil:
		_report(.Error, fmt.tprintf("[Edit Script] waiting for `%s` failed: %v", l.shown, err))
	case state.exit_code != 0:
		_report(.Error, fmt.tprintf("[Edit Script] `%s` exited with %d: %s", l.shown, state.exit_code, text if text != "" else "no error output"))
	case text != "":
		_report(.Warning, fmt.tprintf("[Edit Script] `%s` wrote: %s", l.shown, text))
	}
}

// Off the UI thread the log takes entries through its thread-safe queue.
@(private = "file")
_report :: proc(level: log.Level, msg: string, loc := #caller_location) {
	log.intake_remote(level, time.now(), loc.file_path, int(loc.line), loc.procedure, msg)
}

// The script editor command for a file and line, one word per element, with
// {file} and {line} filled in. A file path with spaces stays one word.
// Temp-allocated.
script_editor_command :: proc(template, file: string, line: int) -> []string {
	words := strings.fields(template, context.temp_allocator)
	line_text := fmt.tprint(line)
	for &w in words {
		w, _ = strings.replace_all(w, "{file}", file, context.temp_allocator)
		w, _ = strings.replace_all(w, "{line}", line_text, context.temp_allocator)
	}
	return words
}

// The line in `path` that declares `name`: `recorded` while it still does,
// else the first line that does, else `recorded`. The file can have changed
// since this build recorded the line.
declaration_line :: proc(path, name: string, recorded: int) -> int {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return recorded
	lines := strings.split_lines(string(data), context.temp_allocator)
	declares :: proc(text, name: string) -> bool {
		t := strings.trim_left_space(text)
		if !strings.has_prefix(t, name) do return false
		return strings.has_prefix(strings.trim_left_space(t[len(name):]), "::")
	}
	if recorded >= 1 && recorded <= len(lines) && declares(lines[recorded - 1], name) do return recorded
	for text, i in lines do if declares(text, name) do return i + 1
	return recorded
}
