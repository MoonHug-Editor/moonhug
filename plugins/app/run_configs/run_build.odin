package run_build

// Build + run under the catalog pipeline (docs/AssetPipeline.md "Asset catalog and builds"): build the game, stage builds/app_data from the editor-maintained
// catalog, run the binary against it — the shipping shape. The pinned scene
// makes every launch of this config produce the same build. The editor's
// Build button forwards its live scene to the RUN only, and --build-only
// stops before the run.

import rc "moonhug:editor/runconfig"

main :: proc() {
	if _, ok := rc.build({package_path = "moonhug/packages/app", out = "builds/app"}); !ok {
		rc.exit_build_failed("moonhug/packages/app")
	}
	if !rc.export_data("builds/app", scene = "packages/app/assets/demo_menu/menu.scene") {
		rc.exit_build_failed("builds/app data")
	}
	rc.run_build("builds/app")
}
