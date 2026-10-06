package editor

// Odin dev-2026-10 stops with "missing procedure 'objc_lookUpClass'" on any
// Objective-C message send (dock_icon_darwin.odin, project_os_darwin.odin)
// unless the program also calls objc_find_class and objc_find_selector: only
// those make the checker add the runtime procs the backend calls at startup
// (odin-lang/Odin#7793). These two lookups run once at program init and cost
// nothing. They are needed while that issue is open.

import "base:intrinsics"

@(init, private = "file")
_objc_runtime_deps :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
	_ = intrinsics.objc_find_selector("alloc")
}
