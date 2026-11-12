package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "09aa3e56-5ba6-4a03-92c6-daecd52ca205" // physics3d_sample.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/physics3d_sample"}, SCENE)
}
