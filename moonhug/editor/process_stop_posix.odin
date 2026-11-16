#+build !windows
package editor

import "core:os"
import "core:sys/posix"

// Asks a child process to end. A run config passes it on to the game it
// started (runconfig/stop_posix.odin).
process_stop :: proc(p: os.Process) {
	if p.pid > 0 do posix.kill(posix.pid_t(p.pid), .SIGTERM)
}
