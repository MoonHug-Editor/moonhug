package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
SCENE :: "packages/physics3d_sample/assets/physics3d_sample.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/physics3d_sample"}, SCENE)
}
