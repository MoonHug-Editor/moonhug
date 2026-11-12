package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "5d2e9c81-7a46-4f03-b1c8-92e05a4d7f36" // particles_samples.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/particles_sample"}, SCENE)
}
