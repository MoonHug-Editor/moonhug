package gen_facts

// Keeps a manifest's `dependencies` equal to what the scan finds
// (plugin_uses.odin). Prebuild runs it on every build, `mh deps` on demand.
// `dependencies_custom` is never touched.

import "core:crypto"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Plugin_Manifest_Sync :: struct {
	path:    string,
	made:    bool,     // there was no manifest, one was written
	added:   []string, // now in dependencies
	removed: []string, // no longer in dependencies
}

// Reads the plugin's manifest (or makes one), sets `dependencies` to `found`
// and writes it back when anything differs. ok=false when the manifest does
// not parse or names another plugin, with the reason printed. Temp strings.
plugin_manifest_sync :: proc(p: Plugin_Folder, found: []string) -> (r: Plugin_Manifest_Sync, changed: bool, ok: bool) {
	m, has_manifest, parsed := plugin_manifest_read(p.dir)
	r.path = strings.join({p.dir, PLUGIN_MANIFEST}, "/", context.temp_allocator)
	if has_manifest && !parsed {
		fmt.eprintfln("%s does not parse, fix or delete it", r.path)
		return r, false, false
	}
	if !has_manifest {
		context.random_generator = crypto.random_generator()
		m = Plugin_Manifest{name = p.name, guid = uuid.to_string(uuid.generate_v4(), context.temp_allocator)}
		r.made = true
	}
	if m.name != p.name {
		fmt.eprintfln("%s names the plugin %q, its folder is %q", r.path, m.name, p.name)
		return r, false, false
	}

	wanted := slice.clone(found, context.temp_allocator)
	slice.sort(wanted)
	added := make([dynamic]string, context.temp_allocator)
	removed := make([dynamic]string, context.temp_allocator)
	for d in wanted do if !slice.contains(m.dependencies, d) do append(&added, d)
	for d in m.dependencies do if !slice.contains(wanted, d) do append(&removed, d)
	r.added, r.removed = added[:], removed[:]
	// A manifest from before dependencies_custom existed gets the key, so the
	// file shows where a hand-written entry goes.
	has_custom_key := false
	if has_manifest {
		if data, err := os.read_entire_file(r.path, context.temp_allocator); err == nil {
			has_custom_key = strings.contains(string(data), "\"dependencies_custom\"")
		}
	}
	if !r.made && has_custom_key && len(added) == 0 && len(removed) == 0 do return r, false, true

	m.dependencies = wanted
	if !plugin_manifest_write(r.path, m) {
		fmt.eprintfln("failed to write %s", r.path)
		return r, true, false
	}
	return r, true, true
}

// The manifest in a fixed key order, one list per line.
plugin_manifest_write :: proc(path: string, m: Plugin_Manifest) -> bool {
	quote :: proc(s: string) -> string {
		data, err := json.marshal(s, allocator = context.temp_allocator)
		return string(data) if err == nil else "\"\""
	}
	list :: proc(b: ^strings.Builder, key: string, items: []string) {
		fmt.sbprintf(b, "  \"%s\": [", key)
		for d, i in items {
			if i > 0 do strings.write_string(b, ", ")
			strings.write_string(b, quote(d))
		}
		strings.write_string(b, "]")
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n  \"name\": %s,\n  \"guid\": %s,\n  \"description\": %s,\n", quote(m.name), quote(m.guid), quote(m.description))
	list(&b, "dependencies", m.dependencies)
	strings.write_string(&b, ",\n")
	list(&b, "dependencies_custom", m.dependencies_custom)
	strings.write_string(&b, "\n}\n")
	return os.write_entire_file(path, transmute([]byte)strings.to_string(b)) == nil
}

// Syncs every manifest on disk from one scan. Prints one line per manifest
// that changed. ok=false when one failed.
plugin_manifests_sync_all :: proc(prefix: string) -> (ok: bool) {
	ok = true
	rows := plugin_deps_on_disk()
	for p in plugin_folders() {
		found := make([dynamic]string, context.temp_allocator)
		for r in rows do if r.plugin == p.name do append(&found, r.needs)
		r, changed, sok := plugin_manifest_sync(p, found[:])
		if !sok { ok = false; continue }
		if !changed do continue
		if r.made {
			fmt.printfln("%s%s: made %s", prefix, p.name, r.path)
			continue
		}
		if len(r.added) == 0 && len(r.removed) == 0 {
			fmt.printfln("%s%s: %s gets dependencies_custom", prefix, p.name, PLUGIN_MANIFEST)
			continue
		}
		fmt.printfln("%s%s: %s dependencies updated (+%d -%d)", prefix, p.name, PLUGIN_MANIFEST, len(r.added), len(r.removed))
	}
	return ok
}
