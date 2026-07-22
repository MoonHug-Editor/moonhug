package editor

// Packages section of the project view (docs/Plugins.md). Each installed
// package's assets/ folder is an ADDITIONAL ROOT, the same concept as the
// Assets root: label = package name, path = packages/<name>/assets. The
// Packages node and the package rows are special the way the Assets root is —
// non-renameable, non-deletable, no file ops on the rows themselves.
// Everything BELOW a package root is regular real paths.

import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "inspector"
import "../engine"

_PROJECT_PACKAGES_PATH :: "packages"

Project_Package :: struct {
	name:        string, // temp
	assets_path: string, // temp; "packages/<name>/assets"
}

// Installed packages via the dir cache (500ms TTL — same freshness as the
// rest of the project view). Temp-allocated.
project_packages_list :: proc() -> []Project_Package {
	entries, ok := project_dir_listing(_PROJECT_PACKAGES_PATH)
	if !ok do return nil
	out := make([dynamic]Project_Package, context.temp_allocator)
	for entry in entries {
		if !entry.is_dir do continue
		if strings.has_prefix(entry.name, ".") do continue
		append(&out, Project_Package{
			name        = strings.clone(entry.name, context.temp_allocator),
			assets_path = fmt.tprintf("%s/%s/assets", _PROJECT_PACKAGES_PATH, entry.name),
		})
	}
	return out[:]
}

// "packages/<name>/assets" with exactly one segment for <name>.
project_path_is_package_root :: proc(path: string) -> bool {
	prefix :: _PROJECT_PACKAGES_PATH + "/"
	if !strings.has_prefix(path, prefix) do return false
	rest := path[len(prefix):]
	i := strings.index(rest, "/")
	if i <= 0 do return false
	return rest[i + 1:] == "assets"
}

// "packages/<name>/assets" -> "<name>".
project_package_root_name :: proc(path: string) -> string {
	rest := path[len(_PROJECT_PACKAGES_PATH) + 1:]
	return rest[:strings.index(rest, "/")]
}

// Roots (Assets, Packages, each package) are structural: no rename, no file
// ops on the row itself. Mirrors the existing Assets-root guard.
project_path_is_protected :: proc(path: string) -> bool {
	return path == projectViewData.rootPath ||
	       path == _PROJECT_PACKAGES_PATH ||
	       project_path_is_package_root(path)
}

// Parent for "go up" navigation, aware of the package roots: a package root's
// parent is the Packages node (never the raw package folder, which would
// expose code to the file list), and the Packages node is a top.
_project_parent_dir :: proc(path: string) -> (parent: string, ok: bool) {
	if path == projectViewData.rootPath || path == _PROJECT_PACKAGES_PATH do return "", false
	if project_path_is_package_root(path) do return _PROJECT_PACKAGES_PATH, true
	if i := strings.last_index(path, "/"); i > 0 {
		return path[:i], true
	}
	return projectViewData.rootPath, true
}

// Tree: the Packages top node with one child node per package root. Reuses
// the regular folder-node drawing for the roots — label is the package name,
// path is the real assets dir, so everything below is ordinary.
_project_draw_packages_tree :: proc() {
	pkgs := project_packages_list()

	im.PushID("##packages_root")
	defer im.PopID()

	is_selected := _project_active_pane == .Tree && projectViewData.currentPath == _PROJECT_PACKAGES_PATH
	node_flags: im.TreeNodeFlags = {.OpenOnArrow, .OpenOnDoubleClick}
	if is_selected do node_flags += {.Selected}
	if len(pkgs) == 0 do node_flags += {.Leaf, .NoTreePushOnOpen}

	if len(pkgs) > 0 {
		if _project_tree_set_open_path == _PROJECT_PACKAGES_PATH {
			im.SetNextItemOpen(_project_tree_set_open_val)
			delete(_project_tree_set_open_path)
			_project_tree_set_open_path = ""
		} else if _project_tree_reveal && _project_path_is_ancestor(_PROJECT_PACKAGES_PATH, projectViewData.currentPath) {
			im.SetNextItemOpen(true)
		}
	}

	expanded := len(pkgs) > 0 && _project_tree_open_state[_PROJECT_PACKAGES_PATH]
	icon := ICON_MD_FOLDER_OPEN if expanded else ICON_MD_FOLDER
	label := strings.clone_to_cstring(fmt.tprintf("%sPackages###node", icon), context.temp_allocator)

	node_open := im.TreeNodeEx(label, node_flags)
	open := node_open && len(pkgs) > 0
	append(&_project_tree_rows, Project_Tree_Row{path = _PROJECT_PACKAGES_PATH, open = open})
	if _, seen := _project_tree_open_state[_PROJECT_PACKAGES_PATH]; seen {
		_project_tree_open_state[_PROJECT_PACKAGES_PATH] = open
	} else {
		_project_tree_open_state[strings.clone(_PROJECT_PACKAGES_PATH)] = open
	}
	if is_selected && _project_scroll_to_tree_sel {
		im.SetScrollHereY()
		_project_scroll_to_tree_sel = false
	}
	if im.IsItemClicked() {
		_project_set_current(_PROJECT_PACKAGES_PATH)
	}
	if node_open && len(pkgs) > 0 {
		for pkg in pkgs {
			_project_draw_tree_node(pkg.assets_path, pkg.name)
		}
		im.TreePop()
	}
}

// File list when browsing the Packages node: one row per package. Selecting
// opens the package inspector, double-click enters the package root.
_project_draw_packages_list :: proc() {
	for pkg in project_packages_list() {
		append(&_project_list_rows, Project_Row{name = pkg.name, path = pkg.assets_path, is_dir = true})
		label := strings.clone_to_cstring(fmt.tprintf("%s%s", ICON_MD_FOLDER, pkg.name), context.temp_allocator)
		is_selected := _project_active_pane == .List && sel_proj_is(pkg.assets_path)
		if im.Selectable(label, is_selected, {.AllowDoubleClick}) {
			_project_set_selected(pkg.assets_path)
			inspector.load_package(pkg.name, pkg.assets_path, _project_package_asset_count(pkg.assets_path))
			if im.IsMouseDoubleClicked(.Left) {
				_project_enter_dir(pkg.assets_path)
			}
		}
		if is_selected && _project_scroll_to_list_sel {
			im.SetScrollHereY()
			_project_scroll_to_list_sel = false
		}
	}
}

_project_package_asset_count :: proc(assets_path: string) -> int {
	prefix := fmt.tprintf("%s/", assets_path)
	count := 0
	for path in engine.asset_db.path_to_guid {
		if strings.has_prefix(path, prefix) do count += 1
	}
	return count
}
