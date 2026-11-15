package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "00b9e2aa-40e2-42f7-a99e-22170d09e99c" // tween_demo.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/tween_sample"}, SCENE)
}
