#+build windows
package runconfig

// Windows has no signal to pass on: the editor ends the config's process, and
// the game it started ends with the closed pipes.

@(private)
_stop_install :: proc() {}

@(private)
_stop_child_set :: proc(pid: int) {}
