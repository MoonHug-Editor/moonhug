package engine

// Groups (docs/Groups.md): an object belongs to any of 32 named groups, and
// game code asks for every member of one. A Groups component on the object
// holds its membership as a bit per group. The names live in a Group Names
// asset, picked by the Groups project setting, registered as the "group"
// layer domain, so the inspector's layer picker edits the bits and a rename
// reaches it at once, as the render layers do (layers_asset.odin).
//
// Membership is indexed by the game lifecycle hooks (component_lifecycle.odin):
// - comp_awake adds the object to the alive list of each of its groups,
//   comp_on_destroy removes it.
// - comp_on_enable adds it to the active list, comp_on_disable removes it.
// So group_alive and group_active are lists, kept up to date on every path a
// creation, a destroy or an enable change takes, and they run only while the
// game runs: in edit mode they are empty. A change of membership at runtime
// goes through groups_set, which moves the object between lists.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "moonhug:libs/log"

// The names of the 32 groups. An empty name is an unused group.
@(typ_guid={guid = "9d4c2b7e-1a53-4f8e-b6d0-3e7a5c91f2b4", menu_assets_create = {menu_name = "Group Names", file_name = "GroupNames.asset", order = -3}})
Group_Names :: struct {
	names: [LAYER_COUNT]string `decor:layer_names(builtin="")`,
}

// The layer domain of the groups: the Groups component's bits.
GROUP_DOMAIN :: "group"

reset_Group_Names :: proc(g: ^Group_Names) {
	cleanup_Group_Names(g)
}

cleanup_Group_Names :: proc(g: ^Group_Names) {
	for s in g.names do delete(s)
	g^ = {}
}

// The Groups project setting: which Group Names asset the project uses. Unset
// is no names.
Groups_Settings :: struct {
	group_names: Asset_GUID `ref:"Group_Names"`,
}

@(project_settings={name="Groups"})
groups_settings: Groups_Settings

// The groups an object belongs to, one bit per group of the Group Names
// asset. Disabled, the object stays alive in its groups but leaves the active
// lists.
@(component={menu="Scene/Groups"})
@(typ_guid={guid = "4b8e7d12-6f3a-4c95-a1e0-2d7c9b5f8e31"})
Groups :: struct {
	using base: CompData `inspect:"-"`,
	groups: u32 `decor:layers(domain="group")`,
}

// --- The names: the active asset's copy, registered as the group domain ---

@(private = "file")
_group_names: struct {
	names:  [LAYER_COUNT]string,
	guid:   Asset_GUID,
	loaded: bool,
}

@(private = "file") _groups_settings_loaded: bool

@(init)
_groups_register :: proc "contextless" () {
	context = runtime.default_context()
	layer_domain_register(GROUP_DOMAIN, &_group_names.names, refresh = groups_sync)
	asset_db_add_evict_hook(_group_names_path_changed)
}

groups_settings_ensure_loaded :: proc() {
	if _groups_settings_loaded do return
	_groups_settings_loaded = true
	project_settings_load("Groups", &groups_settings)
}

// Brings the registered names up to date with the asset the Groups setting
// names. A cheap check when nothing changed. Every read of the names calls it
// (layer_domain_register's refresh).
groups_sync :: proc() {
	context.allocator = runtime.default_allocator()
	groups_settings_ensure_loaded()
	want := groups_settings.group_names
	if _group_names.loaded && _group_names.guid == want do return
	_group_names.loaded = true
	_group_names.guid = want
	src: Group_Names
	ok: bool
	if want != {} do src, ok = asset_load_as(want, Group_Names)
	if !ok {
		if want != {} do log.warningf("[Groups] the Groups setting names no readable Group_Names asset, using no names")
		reset_Group_Names(&src)
	}
	defer cleanup_Group_Names(&src)
	_group_names_copy(&_group_names.names, src.names)
}

// Editor hook: a Group Names document's current values replace the registered
// names when it is the asset the project uses, so an edit in the inspector
// reaches the picker before it is saved.
group_names_preview :: proc(guid: Asset_GUID, g: Group_Names) {
	context.allocator = runtime.default_allocator()
	groups_sync()
	if guid != _group_names.guid do return
	_group_names_copy(&_group_names.names, g.names)
}

@(private = "file")
_group_names_path_changed :: proc(path: string) {
	if !strings.has_suffix(path, ".asset") do return
	guid, ok := asset_db_get_guid(path)
	if !ok do return
	if _group_names.loaded && _group_names.guid == Asset_GUID(guid) do _group_names.loaded = false
}

// The next sync reads the setting and the asset again.
_groups_shutdown :: proc() {
	_groups_settings_loaded = false
	_group_names.loaded = false
	_group_names.guid = {}
}

@(private = "file")
_group_names_copy :: proc(dst: ^[LAYER_COUNT]string, src: [LAYER_COUNT]string) {
	for &name, i in dst {
		if name == src[i] do continue
		delete(name)
		name = strings.clone(src[i])
	}
}

// The group named `name`, as a bit index. Panics when the asset has no such
// group: game code resolves its groups once at startup, so a typo stops the
// game there.
group_index :: proc(name: string) -> int {
	i := layer_index(GROUP_DOMAIN, name)
	fmt.assertf(i >= 0, "groups: the Group Names asset has no group %q", name)
	return i
}

// --- The index: who is alive and who is active in each group ---

@(private = "file")
_group_lists: struct {
	alive:  [LAYER_COUNT][dynamic]Transform_Handle,
	active: [LAYER_COUNT][dynamic]Transform_Handle,
}

// Every awake object in group `g` (a bit index), in the order they awoke.
// Empty outside the running game. The slice is the index's own: copy it
// before a loop that destroys or regroups members.
group_alive :: proc(g: int) -> []Transform_Handle {
	return _group_lists.alive[g][:]
}

// The members of group `g` whose Groups component is enabled on an active
// object. Empty outside the running game. The slice is the index's own.
group_active :: proc(g: int) -> []Transform_Handle {
	return _group_lists.active[g][:]
}

// Whether `tH` is in group `g`: the component's bit, in every mode.
in_group :: proc(tH: Transform_Handle, g: int) -> bool {
	_, c := transform_get_comp(tH, Groups)
	return c != nil && c.groups & (u32(1) << u32(g)) != 0
}

// Changes an object's membership at runtime: the lists follow. A raw write
// of `groups` while the game runs leaves the lists stale until groups_resync.
groups_set :: proc(c: ^Groups, groups: u32) {
	if c.groups == groups do return
	c.groups = groups
	groups_resync(c)
}

// Brings the lists in line with the component's bits, whatever wrote them:
// the editor's value writes reach it through the undo stack
// (editor_value_written). A no-op outside the running game.
groups_resync :: proc(c: ^Groups) {
	if !game_running() do return
	_lists_remove(&_group_lists.alive, c.owner, ~c.groups)
	_lists_remove(&_group_lists.active, c.owner, ~c.groups)
	_lists_add(&_group_lists.alive, c.owner, c.groups)
	if c.notified_enabled {
		_lists_add(&_group_lists.active, c.owner, c.groups)
	} else {
		_lists_remove(&_group_lists.active, c.owner, c.groups)
	}
}

@(comp_awake={component=Groups})
comp_awake_Groups :: proc(c: ^Groups) {
	_lists_add(&_group_lists.alive, c.owner, c.groups)
}

@(comp_on_destroy={component=Groups})
comp_on_destroy_Groups :: proc(c: ^Groups) {
	_lists_remove(&_group_lists.alive, c.owner, c.groups)
}

@(comp_on_enable={component=Groups})
comp_on_enable_Groups :: proc(c: ^Groups) {
	_lists_add(&_group_lists.active, c.owner, c.groups)
}

@(comp_on_disable={component=Groups})
comp_on_disable_Groups :: proc(c: ^Groups) {
	_lists_remove(&_group_lists.active, c.owner, c.groups)
}

// Adds `tH` to the lists of `mask`'s groups, once each. The lists are
// cross-frame state, so they pin the default allocator.
@(private = "file")
_lists_add :: proc(lists: ^[LAYER_COUNT][dynamic]Transform_Handle, tH: Transform_Handle, mask: u32) {
	for i in 0 ..< LAYER_COUNT {
		if mask & (u32(1) << u32(i)) == 0 do continue
		l := &lists[i]
		if l.allocator.procedure == nil do l^ = make([dynamic]Transform_Handle, runtime.default_allocator())
		found := false
		for h in l do if h == tH { found = true; break }
		if !found do append(l, tH)
	}
}

@(private = "file")
_lists_remove :: proc(lists: ^[LAYER_COUNT][dynamic]Transform_Handle, tH: Transform_Handle, mask: u32) {
	for i in 0 ..< LAYER_COUNT {
		if mask & (u32(1) << u32(i)) == 0 do continue
		l := &lists[i]
		for h, j in l {
			if h == tH {
				ordered_remove(l, j)
				break
			}
		}
	}
}
