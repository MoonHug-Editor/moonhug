package run

// Run configuration (docs/Plugins.md): one call does it all. Plain: build the
// app runner as builds/physics2d_sample, export the physics2d sample's data dir, run the export. Alt: dev run against the
// editor's live catalog. Shift: run the last build. Alt+Shift: build only.
// The editor's Play passes its live-scene snapshot as the program argument,
// which takes priority for the run.

import rc "moonhug:editor/runconfig"

// The app normalizes its cwd to moonhug/, so the scene path is moonhug-relative.
SCENE :: "packages/physics2d_sample/assets/physics2d_sample.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/physics2d_sample"}, SCENE)
}
