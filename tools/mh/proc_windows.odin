#+build windows
package mh

import "core:os"

// process_alive reports whether a process with this pid exists: opening a
// handle to a dead pid fails.
process_alive :: proc(pid: int) -> bool {
	p, err := os.process_open(pid)
	if err != nil do return false
	defer os.process_close(p)
	return true
}
