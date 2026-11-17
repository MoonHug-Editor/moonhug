package audio_editor

// The Audio Mixer asset in the editor (audio/mixer.odin):
//
// - Its groups are its sub-assets, of kind "mixergroup": the Project window
//   unfolds a mixer to them, and an AudioSource's `output` picks one. The
//   asset database lists them from the file, and again on every edit.
// - The Inspector shows the groups as a tree. A click selects a group and
//   its volume, mute and effects show under the tree. Add Group puts a group
//   under the selected one, a group dragged onto another moves under it.
// - Every edit is heard at once (audio.mixer_preview), saved or not.

import "base:runtime"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import "moonhug:editor/inspector"
import "moonhug:editor/subassets"
import "moonhug:editor/widgets"
import assets "moonhug:libs/assets"
import engine "moonhug:packages/engine"
import audio "moonhug:packages/audio"

MIXER_EXT :: ".mixer"
MIXER_GROUP_KIND :: "mixergroup"

@(provider_install)
mixer_editor_install :: proc() {
	subassets.register(MIXER_EXT, subassets.Provider{list = _mixer_groups})
	assets.asset_db_add_indexer(MIXER_EXT, _index_mixer_groups)
}

// The groups the database lists for the mixer at `path`.
@(private = "file")
_mixer_groups :: proc(path: string, allocator: runtime.Allocator) -> []subassets.Sub_Asset {
	guid, ok := engine.asset_db_get_guid(path)
	if !ok do return nil
	list := assets.asset_db_sub_assets(engine.Asset_GUID(guid))
	if len(list) == 0 do return nil
	out := make([]subassets.Sub_Asset, len(list), allocator)
	for s, i in list do out[i] = {id = s.id, name = s.name, kind = s.kind}
	return out
}

@(private = "file")
_index_mixer_groups :: proc(guid: engine.Asset_GUID, path: string, data: []byte) {
	m, ok := assets.asset_parse_as(data, audio.AudioMixer)
	if !ok do return
	defer audio.type_cleanup_AudioMixer(&m)
	_publish_groups(guid, &m)
}

@(private = "file")
_publish_groups :: proc(guid: engine.Asset_GUID, m: ^audio.AudioMixer) {
	list := make([]assets.Asset_Sub_Info, len(m.groups), context.temp_allocator)
	for g, i in m.groups do list[i] = {id = engine.Local_ID(g.id), name = g.name, kind = MIXER_GROUP_KIND}
	assets.asset_db_sub_assets_set(guid, list)
}

@(doc_on_changed={type=audio.AudioMixer})
doc_on_changed_AudioMixer :: proc(guid: engine.Asset_GUID, doc: any) {
	m := cast(^audio.AudioMixer)doc.data
	audio.mixer_preview(guid, m)
	_publish_groups(guid, m)
}

// --- The Inspector -------------------------------------------------------------

// The mixer the Inspector shows, its file, and its selected group. The
// Duck's drawer lists that mixer's groups. The selection follows the file:
// Save and Undo give the document new data.
@(private = "file")
_view: struct {
	mixer:    ^audio.AudioMixer,
	file:     engine.Asset_GUID,
	selected: i64,
}

@(private = "file")
_GROUP_PAYLOAD :: "MH_MIXER_GROUP"

@(property_drawer={type=audio.AudioMixer})
property_drawer_AudioMixer :: proc(ctx: ^inspector.Ctx) {
	m := cast(^audio.AudioMixer)ctx.ptr
	if len(m.groups) == 0 do return
	file: engine.Asset_GUID
	if doc := inspector.asset_doc_of(ctx.ptr); doc != nil do file = doc.ref.guid
	if _view.file != file || audio.mixer_group(m, _view.selected) == nil {
		_view.file = file
		_view.selected = m.groups[0].id
	}
	_view.mixer = m

	im.SeparatorText("Groups")
	move_id, move_to: i64
	_draw_group(m, 0, &move_id, &move_to)
	if move_id != 0 {
		sess := inspector.structural_edit_begin("Move Group")
		audio.mixer_group(m, move_id).parent = move_to
		_sort_groups(m)
		inspector.structural_edit_end(&sess)
	}

	if im.Button("Add Group") {
		sess := inspector.structural_edit_begin("Add Group")
		id := m.next_id
		m.next_id += 1
		append(&m.groups, audio.Mixer_Group{id = id, parent = _view.selected, name = strings.clone("New Group")})
		_sort_groups(m)
		inspector.structural_edit_end(&sess)
		_view.selected = id
	}
	widgets.tooltip("Adds a group under the selected one")
	im.SameLine()
	im.BeginDisabled(_view.selected == m.groups[0].id)
	if im.Button("Remove") {
		sess := inspector.structural_edit_begin("Remove Group")
		_remove_group(m, _view.selected)
		inspector.structural_edit_end(&sess)
		_view.selected = m.groups[0].id
	}
	im.EndDisabled()
	widgets.tooltip("Removes the selected group and the groups under it. The Master stays.", im.HoveredFlags_AllowWhenDisabled)

	g := audio.mixer_group(m, _view.selected)
	if g == nil do return
	im.SeparatorText(fmt.ctprintf("%s##selected_group", g.name))
	inspector.draw_value(g, audio.Mixer_Group, "##group")
}

// The groups under `parent` (0: the Master), as tree rows.
@(private = "file")
_draw_group :: proc(m: ^audio.AudioMixer, parent: i64, move_id, move_to: ^i64) {
	for &g in m.groups {
		if g.parent != parent do continue
		has_children := false
		for o in m.groups do if o.parent == g.id do has_children = true
		flags := im.TreeNodeFlags{.OpenOnArrow, .DefaultOpen, .SpanAvailWidth}
		if !has_children do flags += {.Leaf}
		if g.id == _view.selected do flags += {.Selected}
		state := g.mute ? "muted" : fmt.tprintf("%.1f dB", g.volume)
		open := im.TreeNodeEx(fmt.ctprintf("%s   %s###g%d", g.name, state, g.id), flags)
		if im.IsItemClicked() && !im.IsItemToggledOpen() do _view.selected = g.id
		// The Master stays the root.
		if g.parent != 0 && im.BeginDragDropSource() {
			id := g.id
			im.SetDragDropPayload(_GROUP_PAYLOAD, &id, size_of(id))
			im.TextUnformatted(fmt.ctprintf("Move %s", g.name))
			im.EndDragDropSource()
		}
		if im.BeginDragDropTarget() {
			if p := im.AcceptDragDropPayload(_GROUP_PAYLOAD); p != nil {
				from := (^i64)(p.Data)^
				// Never under itself or a group of its own.
				if !audio.mixer_group_is_under(m, g.id, from) {
					move_id^, move_to^ = from, g.id
				}
			}
			im.EndDragDropTarget()
		}
		if open {
			_draw_group(m, g.id, move_id, move_to)
			im.TreePop()
		}
	}
}

// Orders the groups as the tree reads, the Master first and each group after
// its parent, siblings in the order they had.
@(private = "file")
_sort_groups :: proc(m: ^audio.AudioMixer) {
	sorted := make([dynamic]audio.Mixer_Group, 0, len(m.groups), context.temp_allocator)
	add :: proc(m: ^audio.AudioMixer, out: ^[dynamic]audio.Mixer_Group, parent: i64) {
		for g in m.groups do if g.parent == parent {
			append(out, g)
			add(m, out, g.id)
		}
	}
	add(m, &sorted, 0)
	// A group whose parent is gone is not reached: the order stays.
	if len(sorted) == len(m.groups) do copy(m.groups[:], sorted[:])
}

// Removes the group `id` and every group under it.
@(private = "file")
_remove_group :: proc(m: ^audio.AudioMixer, id: i64) {
	for i := len(m.groups) - 1; i > 0; i -= 1 {
		g := &m.groups[i]
		if !audio.mixer_group_is_under(m, g.id, id) do continue
		delete(g.name)
		delete(g.effects)
		ordered_remove(&m.groups, i)
	}
}

// A Duck picks the group it listens to among its mixer's other groups.
@(property_drawer={type=audio.Mixer_Duck})
property_drawer_Mixer_Duck :: proc(ctx: ^inspector.Ctx) {
	d := cast(^audio.Mixer_Duck)ctx.ptr
	inspector.field_edit_row(&d.by, i64, 0, "by", _draw_duck_by, "Listens To")
	inspector.draw(ctx)
}

@(private = "file")
_draw_duck_by :: proc(ptr: rawptr, tid: typeid, label: cstring) {
	by := cast(^i64)ptr
	names := make([dynamic]cstring, context.temp_allocator)
	ids := make([dynamic]i64, context.temp_allocator)
	append(&names, "None")
	append(&ids, 0)
	if m := _view.mixer; m != nil {
		for g in m.groups do if g.id != _view.selected {
			append(&names, strings.clone_to_cstring(g.name, context.temp_allocator))
			append(&ids, g.id)
		}
	}
	current: i32
	for id, i in ids do if id == by^ do current = i32(i)
	if im.ComboChar(inspector.field_row(label), &current, raw_data(names[:]), i32(len(names))) {
		by^ = ids[current]
	}
}
