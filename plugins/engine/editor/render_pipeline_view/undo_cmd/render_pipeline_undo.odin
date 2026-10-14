package render_pipeline_undo

// The Render Pipeline window's undo step: the whole document before and
// after one edit, as JSON. A pipeline is small, so a snapshot pair is simpler
// than one command per kind of edit and cannot drift from what the edit did.
//
// The command lives in its own package because the generated undo union
// imports it, and a command's package must not import moonhug:editor/undo
// (prebuild/undo_command_gen). The window imports both and installs
// `load_hook`, the proc that puts a snapshot back.

// Loads a snapshot (pipeline JSON) as the document at `path`. Installed by
// the Render Pipeline window.
load_hook: proc(path: string, json: string)

@(undo_command)
Render_Pipeline_Edit :: struct {
	path:   string, // owned
	before: string, // owned, the pipeline JSON before the edit
	after:  string, // owned, the pipeline JSON after the edit
}

apply_Render_Pipeline_Edit :: proc(v: ^Render_Pipeline_Edit) {
	if load_hook != nil do load_hook(v.path, v.after)
}

revert_Render_Pipeline_Edit :: proc(v: ^Render_Pipeline_Edit) {
	if load_hook != nil do load_hook(v.path, v.before)
}

destroy_Render_Pipeline_Edit :: proc(v: ^Render_Pipeline_Edit) {
	delete(v.path)
	delete(v.before)
	delete(v.after)
	v^ = {}
}

label_Render_Pipeline_Edit :: proc(v: ^Render_Pipeline_Edit) -> string {
	return "Render Pipeline Edit"
}
