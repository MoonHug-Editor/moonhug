package engine

import "core:os"
import "core:path/filepath"
import "core:strings"
import "log"

// Locating the moonhug/ source directory, and anchoring the process there.
//
// Every runtime path the engine resolves is relative to it: "assets" (asset db
// root), "library" (artifact cache), "ProjectSettings" (editor_settings.json).
// The editor also derives the repo root as this directory's parent when it
// launches run configs, so the invariant "cwd == <repo>/moonhug" holds before
// anything touches the filesystem.
//
// Detection is by directory CONTENT, not by folder name. A name test —
// `has_suffix(cwd, "moonhug")`, or probing for a "moonhug/engine" child — reads
// the wrong answer when the CHECKOUT ITSELF is named "moonhug", which is what a
// default `git clone` produces: the test passes at the repo root, the chdir is
// skipped, and the process keeps the repo root as its cwd. Nothing errors. The
// asset db scans a nonexistent "assets" and comes up empty, no scene restores,
// and every GameObject menu item is a silent no-op because there is no active
// scene to create into.

// Directories that together identify the moonhug source root. Both are
// committed (ProjectSettings holds a .gitkeep), so a fresh clone has them.
// Requiring BOTH avoids matching an unrelated "assets" folder on the way up.
@(private = "file")
_ROOT_MARKERS :: [?]string{"assets", "ProjectSettings"}

@(private = "file")
_is_project_root :: proc(dir: string) -> bool {
    for marker in _ROOT_MARKERS {
        p, err := filepath.join({dir, marker}, context.temp_allocator)
        if err != nil || !os.is_dir(p) do return false
    }
    return true
}

// project_root_find returns the moonhug/ directory at or above `start`.
//
// Each level tests the directory itself and then its "moonhug" child, so this
// resolves from the repo root, from moonhug/ itself, or from any subdirectory
// (builds/, moonhug/editor/, a package folder).
project_root_find :: proc(start: string, allocator := context.temp_allocator) -> (root: string, ok: bool) {
    dir := start
    for {
        if _is_project_root(dir) {
            r, _ := strings.clone(dir, allocator)
            return r, true
        }
        if nested, jerr := filepath.join({dir, "moonhug"}, context.temp_allocator); jerr == nil && _is_project_root(nested) {
            r, _ := strings.clone(nested, allocator)
            return r, true
        }
        // filepath.dir allocates from context.allocator with no override
        // parameter, so scope the swap: every step of the walk is scratch and
        // would otherwise land in the debug build's tracking allocator.
        parent: string
        {
            context.allocator = context.temp_allocator
            parent = filepath.dir(dir)
        }
        if parent == dir do return "", false // reached the filesystem root
        dir = parent
    }
}

// project_chdir_root anchors the process at the moonhug/ source directory.
// Call once at startup, before any relative path is read.
//
// Panics when the directory is not found. Nothing downstream works without it,
// and every failure it causes is silent — an empty asset db, no restored
// scenes, dead menu items — so a crash naming the cause is the only outcome
// that can be acted on.
project_chdir_root :: proc() -> string {
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        panic("cannot read the working directory")
    }
    found, ok := project_root_find(cwd)
    if !ok {
        log.errorf(
            "cannot locate the moonhug project directory from cwd %q — looked for a directory containing both %q and %q, here and in every parent",
            cwd,
            _ROOT_MARKERS[0],
            _ROOT_MARKERS[1],
        )
        panic("no moonhug project directory found")
    }
    if found == cwd do return found
    if serr := os.set_working_directory(found); serr != nil {
        log.errorf("cannot enter the moonhug project directory %q: %v", found, serr)
        panic("cannot enter the moonhug project directory")
    }
    log.infof("[startup] working directory normalized: %q -> %q", cwd, found)
    return found
}
