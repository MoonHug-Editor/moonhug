package mh_log

import "base:builtin"
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

Level :: enum {
	Info,
	Warning,
	Error,
}

Entry :: struct {
	level:   Level,
	message: string,
	loc:     runtime.Source_Code_Location,
	time:    time.Time,
}

MAX_ENTRIES :: 100

entries: [dynamic]Entry

info :: proc(msg: string, loc := #caller_location) {
	fmt.println(msg)
	append_entry(.Info, msg, loc)
}

warning :: proc(msg: string, loc := #caller_location) {
	fmt.println(msg)
	append_entry(.Warning, msg, loc)
}

error :: proc(msg: string, loc := #caller_location) {
	fmt.println(msg)
	append_entry(.Error, msg, loc)
}

infof :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	info(fmt.tprintf(fmt_str, ..args), loc)
}

warningf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	warning(fmt.tprintf(fmt_str, ..args), loc)
}

errorf :: proc(fmt_str: string, args: ..any, loc := #caller_location) {
	error(fmt.tprintf(fmt_str, ..args), loc)
}

clear :: proc() {
	for entry in entries {
		delete(entry.message)
	}
	builtin.clear(&entries)
}

shutdown :: proc() {
	clear()
	delete(entries)
}

append_entry :: proc(level: Level, msg: string, loc := #caller_location) {
	for len(entries) >= MAX_ENTRIES {
		delete(entries[0].message)
		ordered_remove(&entries, 0)
	}
	append(&entries, Entry{level = level, message = strings.clone(msg), loc = loc, time = time.now()})
}

ordered_remove :: proc(s: ^[dynamic]Entry, index: int) {
	if index < 0 || index >= len(s) do return
	for i in index ..< len(s) - 1 {
		s[i] = s[i + 1]
	}
	pop(s)
}
