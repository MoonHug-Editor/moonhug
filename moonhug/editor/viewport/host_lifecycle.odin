package viewport

import "base:runtime"
import "moonhug:editor/provider"

// The installed engine's boot and shutdown, as the editor's main calls them.
// The engine installs the procs from @(init) (plugins/engine/editor/host).
// With none installed the editor boots to an empty shell with no world.

Host_Lifecycle :: struct {
	// Creates the engine's user context and world. Returns the pointer main
	// sets as context.user_ptr (a callee cannot set its caller's context).
	// Called before anything touches a world.
	boot:     proc() -> rawptr,
	// Starts the engine's caches. Called at EditorInit, after the asset
	// database is scanned and imported.
	init:     proc(),
	// Stops the caches, the scene manager and the scene library. Called at
	// EditorShutdown.
	shutdown: proc(),
	// Destroys the world and the user context `boot` made. Called last, as
	// main returns.
	release:  proc(),
}

@(private) _host_lifecycle: Host_Lifecycle

@(init)
_register_host_lifecycle :: proc "contextless" () {
	context = runtime.default_context()
	provider.register("Host_Lifecycle", &_host_lifecycle)
}

set_host_lifecycle :: proc(h: Host_Lifecycle) {
	_host_lifecycle = h
}

host_boot :: proc() -> rawptr {
	if _host_lifecycle.boot == nil do return nil
	return _host_lifecycle.boot()
}

host_init :: proc() {
	if _host_lifecycle.init != nil do _host_lifecycle.init()
}

host_shutdown :: proc() {
	if _host_lifecycle.shutdown != nil do _host_lifecycle.shutdown()
}

host_release :: proc() {
	if _host_lifecycle.release != nil do _host_lifecycle.release()
}
