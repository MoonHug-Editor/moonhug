package run

import rc "moonhug:editor/runconfig"

// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "f2995ecf-519b-4ac2-9538-dfdaf5d97f4b" // ui_demo.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/mhgui_sample"}, SCENE)
}
