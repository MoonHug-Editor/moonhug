package engine

import "core:os"
import "core:path/filepath"
import "core:strings"
import "log"

// Locating the moonhug/ source directory, and anchoring the process there.
//
// Every runtime path the engine resolves is relative to it: "assets" (asset db
// root), "library" (artifact cache), "ProjectSettings" (editor_settings.json).
// The editor additionally derives the REPO ROOT as this directory's parent when
// launching run configs, so the invariant "cwd == <repo>/moonhug" has to hold
// before anything touches the filesystem.
//
// Detection is by directory CONTENT, not by folder name. The name-based test
// this replaced — `if !strings.has_suffix(cwd, "moonhug") { chdir("moonhug") }`
// — silently no-ops whenever the CHECKOUT ITSELF is named "moonhug"
// (C:\Projects\moonhug, ~/src/moonhug): the suffix already matches, so the
// process keeps the repo root as its cwd. Nothing errors. The asset db just
// scans a nonexistent "assets", no scene is restored, and every GameObject menu
// item becomes a silent no-op because there is no active scene to create into.

// Directories that together identify the moonhug source root. Both are
// committed (ProjectSettings holds a .gitkeep), so a fresh clone has them, and
// requiring BOTH avoids matching some unrelated "assets" folder on the way up.
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
// At each level it tests the directory itself and then its "moonhug" child, so
// this resolves from the repo root, from moonhug/ itself, or from any
// subdirectory (builds/, moonhug/editor/, a package folder).
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
        // filepath.dir allocates from context.allocator with no way to override
        // it; scope the swap so the walk never reaches the debug build's
        // tracking allocator (every step here is scratch).
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
// Leaves the cwd untouched when the directory cannot be found — moving
// somewhere arbitrary would only trade one silent misresolution for another —
// and logs what it looked for.
project_chdir_root :: proc() -> (root: string, ok: bool) {
    cwd, err := os.get_working_directory(context.temp_allocator)
    if err != nil {
        log.errorf("[startup] cannot read the working directory: %v", err)
        return "", false
    }
    found, found_ok := project_root_find(cwd)
    if !found_ok {
        log.errorf(
            "[startup] cannot locate the moonhug project directory from cwd %q — looked for a directory containing both %q and %q, here and in every parent. Relative paths (\"assets\", \"library\", \"ProjectSettings\") will not resolve.",
            cwd,
            _ROOT_MARKERS[0],
            _ROOT_MARKERS[1],
        )
        return "", false
    }
    if found == cwd do return found, true
    if serr := os.set_working_directory(found); serr != nil {
        log.errorf("[startup] cannot enter the moonhug project directory %q: %v", found, serr)
        return "", false
    }
    log.infof("[startup] working directory normalized: %q -> %q", cwd, found)
    return found, true
}
