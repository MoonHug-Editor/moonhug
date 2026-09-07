#+build !windows
package mh

import "core:sys/posix"

// process_alive reports whether a process with this pid exists. Signal 0
// delivers nothing and only checks, so a dead pid fails.
process_alive :: proc(pid: int) -> bool {
	return posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK
}
