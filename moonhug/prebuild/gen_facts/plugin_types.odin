package gen_facts

// The types plugins declare, read from the source on disk: every
// @(typ_guid) under plugins/, installed or not. plugin_types_gen turns them
// into the editor's table, and `mh deps` uses the same scan for guid
// ownership.

import "core:os"
import "core:slice"
import "core:strings"

// The plugins as folders on disk, next to moonhug/. Prebuild's cwd is the
// repo root.
PLUGINS_DIR :: "plugins"

Plugin_Type_Decl :: struct {
	guid: string,
	name: string, // the declaration's name, "?" when the scan cannot tell
	pkg:  string, // the plugin or sample
	dir:  string, // the declaring folder
}

// Every plugin and sample folder under `root`, with its name (temp).
Plugin_Folder :: struct {
	name: string,
	dir:  string,
}

plugin_folders :: proc(root := PLUGINS_DIR) -> [dynamic]Plugin_Folder {
	out := make([dynamic]Plugin_Folder, context.temp_allocator)
	for name in plugin_subdirs(root) {
		dir := strings.join({root, name}, "/", context.temp_allocator)
		append(&out, Plugin_Folder{name = name, dir = dir})
		samples := strings.join({dir, "samples"}, "/", context.temp_allocator)
		for sample in plugin_subdirs(samples) {
			append(&out, Plugin_Folder{name = sample, dir = strings.join({samples, sample}, "/", context.temp_allocator)})
		}
	}
	slice.sort_by(out[:], proc(a, b: Plugin_Folder) -> bool { return a.name < b.name })
	return out
}

// Every @(typ_guid) declaration of every plugin and sample on disk, tests,
// generators and a plugin's own samples left out (temp).
plugin_types_on_disk :: proc(root := PLUGINS_DIR) -> [dynamic]Plugin_Type_Decl {
	out := make([dynamic]Plugin_Type_Decl, context.temp_allocator)
	for p in plugin_folders(root) {
		files := make([dynamic]string, context.temp_allocator)
		plugin_files(p.dir, {"samples", "tests", "gen"}, &files)
		for f in files {
			if !strings.has_suffix(f, ".odin") || strings.has_suffix(f, "_generated.odin") do continue
			data, err := os.read_entire_file(f, context.temp_allocator)
			if err != nil do continue
			plugin_scan_typ_guids(string(data), p.name, f[:strings.last_index_byte(f, '/')], &out)
		}
	}
	slice.sort_by(out[:], proc(a, b: Plugin_Type_Decl) -> bool { return a.guid < b.guid })
	return out
}

// @(typ_guid={guid = "..."}) followed, past attributes and comments, by the
// declaration it tags.
plugin_scan_typ_guids :: proc(src, pkg, dir: string, out: ^[dynamic]Plugin_Type_Decl) {
	lines := strings.split_lines(src, context.temp_allocator)
	for line, i in lines {
		if !strings.contains(line, "typ_guid") do continue
		ids := make([dynamic]string, context.temp_allocator)
		plugin_scan_uuids(line, &ids)
		if len(ids) == 0 do continue
		name := "?"
		for next in lines[i + 1:] {
			l := strings.trim_space(next)
			if l == "" || strings.has_prefix(l, "@(") || strings.has_prefix(l, "//") do continue
			if at := strings.index(l, " ::"); at > 0 do name = l[:at]
			break
		}
		append(out, Plugin_Type_Decl{guid = ids[0], name = name, pkg = pkg, dir = dir})
	}
}

// Every uuid in `src` (8-4-4-4-12 hex), lowercased (temp).
plugin_scan_uuids :: proc(src: string, out: ^[dynamic]string) {
	is_hex :: proc(c: u8) -> bool {
		return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
	}
	UUID_LEN :: 36
	i := 0
	for i + UUID_LEN <= len(src) {
		if i > 0 && is_hex(src[i - 1]) {
			i += 1
			continue
		}
		ok := true
		for k in 0 ..< UUID_LEN {
			c := src[i + k]
			dash := k == 8 || k == 13 || k == 18 || k == 23
			if dash ? c != '-' : !is_hex(c) {
				ok = false
				break
			}
		}
		if ok && (i + UUID_LEN == len(src) || !is_hex(src[i + UUID_LEN])) {
			append(out, strings.to_lower(src[i:i + UUID_LEN], context.temp_allocator))
			i += UUID_LEN
			continue
		}
		i += 1
	}
}

// The subfolder names of `dir`, hidden ones left out, sorted (temp).
plugin_subdirs :: proc(dir: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	handle, err := os.open(dir)
	if err != nil do return out
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return out
	for e in entries {
		if e.type == .Directory && !strings.has_prefix(e.name, ".") do append(&out, strings.clone(e.name, context.temp_allocator))
	}
	slice.sort(out[:])
	return out
}

// Every file under `dir`, recursively, leaving out hidden folders and the
// named ones (temp).
plugin_files :: proc(dir: string, skip: []string, out: ^[dynamic]string) {
	handle, err := os.open(dir)
	if err != nil do return
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil do return
	for e in entries {
		if strings.has_prefix(e.name, ".") do continue
		full := strings.join({dir, e.name}, "/", context.temp_allocator)
		if e.type == .Directory {
			if !slice.contains(skip, e.name) do plugin_files(full, skip, out)
			continue
		}
		append(out, full)
	}
}
