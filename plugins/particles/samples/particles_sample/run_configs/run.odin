package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
SCENE :: "packages/particles_sample/assets/particles_samples.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/particles_sample"}, SCENE)
}
