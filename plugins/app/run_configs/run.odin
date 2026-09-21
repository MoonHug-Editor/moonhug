package run

// The app's run configuration (docs/AssetPipeline.md "Asset catalog and
// builds"): build the game, stage builds/app_data from the editor-maintained
// catalog, run the binary against it, the shipping shape. Alt: dev run
// against the live catalog, no export. Shift: run the last build. Alt+Shift:
// build only. The pinned scene makes every plain launch produce the same
// build. The editor's Build button forwards its live scene to the RUN only.

import rc "moonhug:editor/runconfig"

SCENE :: "packages/app/assets/demo_menu/menu.scene"

main :: proc() {
	rc.play({package_path = "moonhug/packages/app", out = "builds/app"}, SCENE)
}
