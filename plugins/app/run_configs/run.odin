package run

import rc "moonhug:editor/runconfig"

// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "b794d34b-3067-4b7e-ac2d-5cd46c16c5c1" // demo_menu.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/app"}, SCENE)
}
