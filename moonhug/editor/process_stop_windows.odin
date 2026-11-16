#+build windows
package editor

import "core:os"

// Ends a child process.
process_stop :: proc(p: os.Process) {
	_ = os.process_kill(p)
}
