package shadergraph_undo

// The Shader Graph window's undo step: the whole document before and after
// one edit, as JSON. A graph is small, so a snapshot pair is simpler than one
// command per kind of edit and cannot drift from what the edit did.
//
// The command lives in its own package because the generated undo union
// imports it, and a command's package must not import moonhug:editor/undo
// (prebuild/undo_command_gen). The window imports both and installs
// `load_hook`, the proc that puts a snapshot back.

// Loads a snapshot (graph JSON) as the document at `path`. Installed by the
// Shader Graph window.
load_hook: proc(path: string, json: string)

@(undo_command)
Shader_Graph_Edit :: struct {
	path:   string, // owned
	before: string, // owned, the graph JSON before the edit
	after:  string, // owned, the graph JSON after the edit
}

apply_Shader_Graph_Edit :: proc(v: ^Shader_Graph_Edit) {
	if load_hook != nil do load_hook(v.path, v.after)
}

revert_Shader_Graph_Edit :: proc(v: ^Shader_Graph_Edit) {
	if load_hook != nil do load_hook(v.path, v.before)
}

destroy_Shader_Graph_Edit :: proc(v: ^Shader_Graph_Edit) {
	delete(v.path)
	delete(v.before)
	delete(v.after)
	v^ = {}
}

label_Shader_Graph_Edit :: proc(v: ^Shader_Graph_Edit) -> string {
	return "Shader Graph Edit"
}
