package run_debug

// The app's run configuration with a -debug build, so console logs carry call
// stacks. Same modifiers as run.odin.

import rc "moonhug:editor/runconfig"

SCENE :: "packages/app/assets/demo_menu/menu.scene"

main :: proc() {
	rc.play({
		package_path = "moonhug/packages/app",
		out          = "builds/app_debug",
		flags        = {"-debug"},
	}, SCENE)
}
