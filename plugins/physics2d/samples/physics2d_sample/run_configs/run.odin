package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "5addeff6-c57f-4ee7-ad67-1a35dfc96b8b" // physics2d_sample.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/physics2d_sample"}, SCENE)
}
