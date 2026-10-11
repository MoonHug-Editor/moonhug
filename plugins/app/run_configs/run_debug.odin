package run_debug

import rc "moonhug:editor/runconfig"

SCENE :: "packages/app/assets/demo_menu/menu.scene"

main :: proc() {
	rc.play({
		package_path = "moonhug/packages/app",
		out          = "builds/app_debug",
		flags        = {"-debug"},
	}, SCENE)
}
