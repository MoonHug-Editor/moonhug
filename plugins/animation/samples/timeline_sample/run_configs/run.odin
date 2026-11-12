package run

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "3eb32d59-e532-46ec-b195-a1c15cd2f971" // timeline_demo.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/timeline_sample"}, SCENE)
}
