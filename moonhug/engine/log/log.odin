package mh_log

import "base:builtin"
import "core:fmt"
import "core:strings"

Level :: enum {
	Info,
	Warning,
	Error,
}

Entry :: struct {
	level:   Level,
	message: string,
}

MAX_ENTRIES :: 100

entries: [dynamic]Entry

info :: proc(msg: string) {
	fmt.println(msg)
	append_entry(.Info, msg)
}

warning :: proc(msg: string) {
	fmt.println(msg)
	append_entry(.Warning, msg)
}

error :: proc(msg: string) {
	fmt.println(msg)
	append_entry(.Error, msg)
}

infof :: proc(fmt_str: string, args: ..any) {
	info(fmt.tprintf(fmt_str, ..args))
}

warningf :: proc(fmt_str: string, args: ..any) {
	warning(fmt.tprintf(fmt_str, ..args))
}

errorf :: proc(fmt_str: string, args: ..any) {
	error(fmt.tprintf(fmt_str, ..args))
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

append_entry :: proc(level: Level, msg: string) {
	for len(entries) >= MAX_ENTRIES {
		delete(entries[0].message)
		ordered_remove(&entries, 0)
	}
	append(&entries, Entry{level = level, message = strings.clone(msg)})
}

ordered_remove :: proc(s: ^[dynamic]Entry, index: int) {
	if index < 0 || index >= len(s) do return
	for i in index ..< len(s) - 1 {
		s[i] = s[i + 1]
	}
	pop(s)
}
