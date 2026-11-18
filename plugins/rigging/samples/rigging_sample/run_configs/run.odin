package run

import rc "moonhug:editor/runconfig"

// The boot scene by its asset guid, so a rename or a move keeps the config valid.
SCENE :: "77bce2ab-c1f7-449b-8590-b5b3debd67bc" // rigging_demo.scene

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/rigging_sample"}, SCENE)
}
