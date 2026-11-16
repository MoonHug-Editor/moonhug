#+build !windows
package runconfig

// A stop from whoever launched the config, the editor when it quits, reaches
// the child the config waits for. A config stopped alone would leave the game
// running with the editor's output pipes still open.

import "core:sys/posix"

// The child `spawn` waits for, 0 for none. Read by the signal handler.
@(private)
_child_pid: posix.pid_t

@(private)
_stop_install :: proc() {
	posix.signal(.SIGTERM, _on_stop)
}

@(private)
_stop_child_set :: proc(pid: int) {
	_child_pid = posix.pid_t(pid)
}

// Only async-signal-safe calls: kill and _exit.
@(private)
_on_stop :: proc "c" (sig: posix.Signal) {
	if _child_pid > 0 do posix.kill(_child_pid, .SIGTERM)
	posix._exit(128 + 15)
}
