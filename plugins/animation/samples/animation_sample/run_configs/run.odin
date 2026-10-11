package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
SCENE :: "packages/animation_sample/assets/animation_demo.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/animation_sample"}, SCENE)
}
