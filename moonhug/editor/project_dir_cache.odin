package editor

// Cached directory listings for the project view. Both panes used to hit the
// filesystem EVERY FRAME — draw_file_list re-read + re-sorted the current
// folder, draw_directory_tree re-read every open tree folder, and
// _project_dir_has_subdir re-scanned per visible node — with a sort
// comparator calling the ALLOCATING strings.to_lower per comparison. At
// 120 fps that was the editor's single biggest CPU consumer (profiled).
//
// Listings are sorted once per scan (case-insensitive, keys computed once)
// and cached per path. Invalidation: explicitly after editor-side file
// mutations (rename, file ops, asset refresh on focus), plus a short TTL so
// external changes still show up quickly — same "no file watcher" stance as
// the asset db, at 2 Hz instead of 120 Hz.

import "core:os"
import "core:slice"
import "core:time"
import strings "core:strings"

Project_Dir_Entry :: struct {
	name:   string, // owned
	is_dir: bool,
}

@(private = "file")
_Dir_Listing :: struct {
	entries: []Project_Dir_Entry, // owned; sorted case-insensitive, dirs mixed
	ok:      bool,                // false = the scan itself failed
	scan_ns: i64,
}

@(private = "file")
_dir_listings: map[string]_Dir_Listing // keys owned

@(private = "file")
_DIR_CACHE_TTL_NS :: i64(500_000_000)

// Sorted listing of `path` (500ms freshness). The slice is owned by the
// cache — use it within the frame, don't hold it.
project_dir_listing :: proc(path: string) -> (entries: []Project_Dir_Entry, ok: bool) {
	now := time.now()._nsec
	if l, found := _dir_listings[path]; found && now - l.scan_ns < _DIR_CACHE_TTL_NS {
		return l.entries, l.ok
	}

	fresh, scan_ok := _dir_scan(path)
	if old, found := _dir_listings[path]; found {
		_listing_free(old)
		_dir_listings[path] = _Dir_Listing{entries = fresh, ok = scan_ok, scan_ns = now}
	} else {
		_dir_listings[strings.clone(path)] = _Dir_Listing{entries = fresh, ok = scan_ok, scan_ns = now}
	}
	return fresh, scan_ok
}

// Drop everything — call after any editor-side file mutation so the UI
// updates the same frame (external changes ride the TTL).
project_dir_cache_invalidate :: proc() {
	for k, l in _dir_listings {
		_listing_free(l)
		delete(k)
	}
	clear(&_dir_listings)
}

project_dir_cache_shutdown :: proc() {
	project_dir_cache_invalidate()
	delete(_dir_listings)
	_dir_listings = nil
}

@(private = "file")
_listing_free :: proc(l: _Dir_Listing) {
	for e in l.entries do delete(e.name)
	delete(l.entries)
}

@(private = "file")
_dir_scan :: proc(path: string) -> ([]Project_Dir_Entry, bool) {
	handle, err := os.open(path)
	if err != nil do return nil, false
	defer os.close(handle)
	infos, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return nil, false
	defer os.file_info_slice_delete(infos, context.temp_allocator)

	// Case-insensitive sort with the lowercase key computed ONCE per entry.
	Sort_Row :: struct {
		lower:  string,
		name:   string,
		is_dir: bool,
	}
	rows := make([dynamic]Sort_Row, 0, len(infos), context.temp_allocator)
	for info in infos {
		append(&rows, Sort_Row{
			lower  = strings.to_lower(info.name, context.temp_allocator),
			name   = info.name,
			is_dir = info.type == .Directory,
		})
	}
	slice.sort_by(rows[:], proc(a, b: Sort_Row) -> bool {
		return a.lower < b.lower
	})

	out := make([]Project_Dir_Entry, len(rows))
	for r, i in rows {
		out[i] = Project_Dir_Entry{name = strings.clone(r.name), is_dir = r.is_dir}
	}
	return out, true
}
