package run_debug

// Debug build: the app captures call stacks for console log lines
// (ODIN_DEBUG-gated in the app process). See run.odin for the contract.

import rc "moonhug:editor/runconfig"

main :: proc() {
	rc.build_and_run({
		package_path = "moonhug/packages/app",
		out          = "builds/app_debug",
		flags        = {"-debug"},
	})
}
