package scenarios

// The Audio Mixer in the Inspector (plugins/audio/editor/mixer_editor.odin):
// a selected mixer file shows its groups as a tree, Add Group puts a group
// under the selected one, Remove takes it away, each as an edit of the file.

import "core:encoding/json"
import "core:fmt"
import "core:testing"

@(private = "file")
_PATH :: "assets/Main.mixer"

@(private = "file")
_MIXER :: `{
  "__type_guid": "cf6fc86b-7790-48e0-b534-e4508d1cf3bd",
  "groups": [
    {"id": 1, "parent": 0, "name": "Master", "volume": 0, "mute": false, "effects": []},
    {"id": 2, "parent": 1, "name": "Music", "volume": -6, "mute": false, "effects": []},
    {"id": 3, "parent": 1, "name": "Dialogue", "volume": 0, "mute": false, "effects": []}
  ],
  "next_id": 4
}`

@(private = "file")
_groups :: proc(r: ^Run) -> json.Array {
	list, _ := at(call(r, "asset_document", fmt.tprintf(`{{"path":%q}}`, _PATH)), "values", "groups").(json.Array)
	return list
}

@(test)
audio_mixer_groups_edit_in_the_inspector :: proc(t: ^testing.T) {
	r := begin(t)
	project_write(r, _PATH, _MIXER)
	editor_start(r)
	select_asset(r, _PATH)
	frames(r, 3)

	window_open(r, "Project Inspector")
	frames(r, 2)
	music, shown := item_rect(r, "Project Inspector", "Music")
	if !testing.expectf(t, shown, "the Inspector shows the mixer's groups") do return
	_, dialogue_shown := item_rect(r, "Project Inspector", "Dialogue")
	testing.expect(t, dialogue_shown, "every one of them")

	// Music selected, Add Group: a group under Music.
	click(r, music.x + 10, music.y + music[3] / 2)
	add, has_add := item_rect(r, "Project Inspector", "Add Group")
	if !testing.expect(t, has_add, "the Add Group button") do return
	remove, has_remove := item_rect(r, "Project Inspector", "Remove")
	if !testing.expect(t, has_remove, "the Remove button") do return
	click(r, add.x + 10, add.y + add[3] / 2)
	frames(r, 2)
	groups := _groups(r)
	if !testing.expectf(t, len(groups) == 4, "a group is added: %v", len(groups)) do return
	added := groups[len(groups) - 1]
	for g in groups do if as_int(at(g, "id")) == 4 do added = g
	testing.expectf(t, as_int(at(added, "parent")) == 2 && as_string(at(added, "name")) == "New Group", "under Music, named New Group: %v", added)
	testing.expectf(t, as_int(at(groups[2], "id")) == 4, "listed right after its parent: %v", groups)

	// Saved: the file holds it.
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	saved, _ := at(project_json(r, _PATH), "groups").(json.Array)
	testing.expectf(t, len(saved) == 4, "Save writes the new group: %v", len(saved))

	// It is selected now: Remove takes it away. The new tree row moved the
	// button one row (19 points) down. (Read before the add: item_rect reads
	// text from each font's last baked size only, and the Inspector draws a
	// second size once a group is added.)
	click(r, remove.x + remove[2] - 10, remove.y + 19 + remove[3] / 2)
	frames(r, 2)
	testing.expectf(t, len(_groups(r)) == 3, "Remove takes the new group away: %v", len(_groups(r)))

	for message in log_errors(r) do testing.expectf(t, false, "the editor reported: %s", message)
	call(r, "invoke_menu", `{"path":"File/Save"}`)
	frames(r, 3)
	editor_quit(r)
}
