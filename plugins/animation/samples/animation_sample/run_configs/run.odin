package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "ebe94cf6-07c5-4733-a3f2-0e61dff07161" // animation_demo.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/animation_sample"}, SCENE)
}
