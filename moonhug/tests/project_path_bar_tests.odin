package tests

// The project view's path bar: the current folder as clickable segments.

import "../editor"
import "core:testing"

// ---------------------------------------------------------------------------
// Project view path bar (project_path_segments): the current folder as
// segments, root first, each carrying the path it navigates to. Package roots
// show the package name under the Packages node, never the raw package folder.

// project_path_segments stops at projectViewData.rootPath, which the editor
// sets at init; these tests set it directly instead of starting a UI.
@(private = "file")
_with_project_root :: proc() {
	editor.projectViewData.rootPath = "assets"
}

@(test)
test_project_path_bar_assets_path :: proc(t: ^testing.T) {
	_with_project_root()
	segments := editor.project_path_segments("assets/textures/ui")
	testing.expect_value(t, len(segments), 3)
	testing.expect_value(t, segments[0].label, "assets")
	testing.expect_value(t, segments[0].path, "assets")
	testing.expect_value(t, segments[1].label, "textures")
	testing.expect_value(t, segments[1].path, "assets/textures")
	testing.expect_value(t, segments[2].label, "ui")
	testing.expect_value(t, segments[2].path, "assets/textures/ui")
}

@(test)
test_project_path_bar_root_is_one_segment :: proc(t: ^testing.T) {
	_with_project_root()
	segments := editor.project_path_segments("assets")
	testing.expect_value(t, len(segments), 1)
	testing.expect_value(t, segments[0].label, "assets")
}

@(test)
test_project_path_bar_package_root_shows_package_name :: proc(t: ^testing.T) {
	_with_project_root()
	// A package's assets folder is its root: labelled with the package name,
	// and its parent is the Packages node.
	segments := editor.project_path_segments("packages/sprites/assets")
	testing.expect_value(t, len(segments), 2)
	testing.expect_value(t, segments[0].label, "packages")
	testing.expect_value(t, segments[0].path, "packages")
	testing.expect_value(t, segments[1].label, "sprites")
	testing.expect_value(t, segments[1].path, "packages/sprites/assets")
}

@(test)
test_project_path_bar_inside_a_package :: proc(t: ^testing.T) {
	_with_project_root()
	segments := editor.project_path_segments("packages/sprites/assets/icons")
	testing.expect_value(t, len(segments), 3)
	testing.expect_value(t, segments[1].label, "sprites")
	testing.expect_value(t, segments[2].label, "icons")
	testing.expect_value(t, segments[2].path, "packages/sprites/assets/icons")
}
