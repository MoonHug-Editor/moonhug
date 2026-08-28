package tests

// The project root is found by directory CONTENT. The case that matters is a
// checkout named "moonhug" — a default `git clone` — where every name-based
// test reads the repo root as already correct and leaves the process one level
// too high, with no error anywhere.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../engine"

@(private = "file")
_ROOT_TMP :: "moonhug/tests/fixtures/_project_root_tmp"

// Builds `dirs` under a scratch tree and returns its absolute path — the walk
// climbs to the filesystem root, so it has to start from an absolute path.
@(private = "file")
_root_tree :: proc(t: ^testing.T, dirs: []string) -> string {
	for d in dirs {
		p, _ := filepath.join({_ROOT_TMP, d}, context.temp_allocator)
		testing.expect(t, os.make_directory_all(p) == nil, "scratch tree")
	}
	abs, err := filepath.abs(_ROOT_TMP, context.temp_allocator)
	testing.expect(t, err == nil, "absolute scratch path")
	return abs
}

@(private = "file")
_root_tree_clear :: proc() {
	os.remove_all(_ROOT_TMP)
}

// A checkout named "moonhug" holding moonhug/: the repo root is NOT the project
// root even though its name matches, and the real root is its child.
@(test)
test_project_root_checkout_named_moonhug :: proc(t: ^testing.T) {
	defer _root_tree_clear()
	base := _root_tree(t, {"moonhug/moonhug/assets", "moonhug/moonhug/ProjectSettings"})

	repo, _ := filepath.join({base, "moonhug"}, context.temp_allocator)
	want, _ := filepath.join({repo, "moonhug"}, context.temp_allocator)

	got, ok := engine.project_root_find(repo)
	testing.expect(t, ok, "root found from a checkout named moonhug")
	testing.expect_value(t, got, want)
}

// Resolves from the source directory itself, from the repo root, and from a
// subdirectory — the three natural launch cwds.
@(test)
test_project_root_from_any_start :: proc(t: ^testing.T) {
	defer _root_tree_clear()
	base := _root_tree(t, {"repo/moonhug/assets", "repo/moonhug/ProjectSettings", "repo/moonhug/editor", "repo/builds"})

	repo, _ := filepath.join({base, "repo"}, context.temp_allocator)
	want, _ := filepath.join({repo, "moonhug"}, context.temp_allocator)

	for rel in ([]string{"moonhug", "", "moonhug/editor", "builds"}) {
		start := repo
		if rel != "" do start, _ = filepath.join({repo, rel}, context.temp_allocator)
		got, ok := engine.project_root_find(start)
		testing.expectf(t, ok, "root found from %q", start)
		testing.expect_value(t, got, want)
	}
}

// One marker is not enough: an unrelated "assets" folder must not latch.
@(test)
test_project_root_requires_both_markers :: proc(t: ^testing.T) {
	defer _root_tree_clear()
	base := _root_tree(t, {"repo/assets", "repo/moonhug/assets"})

	repo, _ := filepath.join({base, "repo"}, context.temp_allocator)
	// The scratch tree lives inside the real project, so the walk finds the
	// real root above it. What matters is that it did not stop at "repo".
	got, ok := engine.project_root_find(repo)
	testing.expect(t, !ok || got != repo, "assets alone does not identify a project root")
}
