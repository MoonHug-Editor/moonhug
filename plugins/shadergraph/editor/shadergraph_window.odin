package shadergraph_editor

// The Shader Graph window (docs/ShaderGraph.md, Editor): the toolbar, the
// blackboard and the selected node's inputs on the left, the node canvas in
// the middle, the generated GLSL on the right.
//
// The window edits the graph's shared asset document (editor/inspector,
// asset_docs.odin), the same instance File/Save, the tab menu and undo reach.
// It keeps the asset's guid and looks the document up at the start of each
// frame, since an undo, a redo or a Discard replaces the instance. Every edit
// changes it in
// place and sets `touched`. Once no widget is active (a drag released, a text
// field left), the document is serialized and compared with `baseline`, the
// JSON last recorded on the undo stack. A difference becomes one undo step on
// the asset holding both snapshots, so a node drag or a literal drag is one
// undo step however many frames it took.

import "base:runtime"
import "core:encoding/uuid"
import "core:fmt"
import "core:strings"
import im "moonhug:external/odin-imgui"
import asset_pipeline "moonhug:editor/assets"
import "moonhug:editor/inspector"
import nc "moonhug:editor/node_canvas"
import "moonhug:editor/undo"
import "moonhug:editor/widgets"
import wnd "moonhug:editor/window"
import "moonhug:libs/log"
import "moonhug:packages/engine"
import sg "moonhug:packages/shadergraph"

_SG_State :: struct {
	guid:     engine.Asset_GUID, // the instance's graph
	failed:   bool,              // the file is not a shader graph, said once
	// The graph's shared document and its instance, looked up at the start
	// of each frame (_sg_fetch). Pointers never survive a frame.
	asset:    ^inspector.Asset_Doc,
	graph:    ^sg.Shader_Graph,
	seen:     rawptr, // the instance the window last worked on: another one means an undo or a Discard replaced it
	cv:       nc.Node_Canvas,
	baseline: string, // heap, the document as last recorded on the undo stack
	touched:  bool,   // an edit happened since the last record
	label:    string, // the pending edit's undo label (a literal)

	// The generated shader or the reasons it failed, rebuilt on every
	// recorded change.
	glsl:        cstring, // heap
	errors:      [dynamic]string, // heap
	error_nodes: [dynamic]i32,

	rename:   int, // blackboard row whose name field is active, -1 = none
	name_buf: [128]u8,
	menu_pos:  [2]f32, // canvas position of the add-node popup
	open_menu: bool,   // the canvas asked for the add-node popup this frame

	notice:       string, // a literal shown in the toolbar until notice_until
	notice_until: f64,
}

// The instance being drawn: each instance of the window keeps its own state
// in its wnd.Window (_sg_instance).
_sg: ^_SG_State

_SG_LEFT_W  :: f32(250) // the side panes' default widths
_SG_RIGHT_W :: f32(340)
_SG_MIN_SIDE :: f32(140)
_SG_MIN_MID  :: f32(200)

// Which side panes the window shows, saved per developer. The toolbar's
// Blackboard and GLSL toggles flip them, and the canvas takes the space.
Shader_Graph_Prefs :: struct {
	hide_blackboard: bool, // the left pane: blackboard and the selected node's inputs
	hide_glsl:       bool, // the right pane: the generated shader
	left_w:          f32,  // the left pane's width, 0 = the default
	right_w:         f32,  // the right pane's width, 0 = the default
}

@(user_settings={name="Shader Graph"})
shader_graph_prefs: Shader_Graph_Prefs

_SG_PORT_COLS := [sg.Port_Type]im.Vec4{
	.Float = {0.60, 0.75, 0.95, 1},
	.Vec2  = {0.56, 0.78, 0.44, 1},
	.Vec3  = {0.95, 0.80, 0.35, 1},
	.Vec4  = {0.87, 0.44, 0.67, 1},
	.Dyn   = {0.75, 0.75, 0.75, 1},
}

_SG_PROP_KIND_NAMES := [sg.Prop_Kind]cstring{
	.Float   = "Float",
	.Vec2    = "Vector 2",
	.Vec3    = "Vector 3",
	.Vec4    = "Vector 4",
	.Color   = "Color",
	.Texture = "Texture",
}

// Opens the graph at `path` in its own instance of the window, so two graphs
// are edited side by side. Its unsaved edits stay in its document, so closing
// the instance and opening it again keeps them.
shader_graph_open :: proc(path: string, guid: engine.Asset_GUID) {
	wnd.open("shader_graph", guid)
}

// An instance's state, created on its first frame.
@(private = "file")
_sg_instance :: proc(w: ^wnd.Window) -> ^_SG_State {
	if w.data == nil {
		st := new(_SG_State, runtime.default_allocator())
		st^ = {guid = w.asset, rename = -1}
		st.cv.sel = -1
		st.cv.sel_link = -1
		w.data = st
	}
	return (^_SG_State)(w.data)
}

// Frees an instance's state, on the default allocator like the rest of the
// window's own state.
shader_graph_window_closed :: proc(w: ^wnd.Window) {
	st := (^_SG_State)(w.data)
	if st == nil do return
	context.allocator = runtime.default_allocator()
	delete(st.baseline)
	delete(st.glsl)
	for e in st.errors do delete(e)
	delete(st.errors)
	delete(st.error_nodes)
	if _sg == st do _sg = nil
	free(st)
	w.data = nil
}

// Looks up the open graph's shared document, loading it on first use. A new
// instance (the first frame, an undo, a redo, a Discard) rebuilds what the
// window derives from it: the recorded baseline, the generated shader, the
// selection. False when nothing is open or the file is not a shader graph.
@(private = "file")
_sg_fetch :: proc() -> bool {
	context.allocator = runtime.default_allocator()
	_sg.asset = nil
	_sg.graph = nil
	if _sg.guid == {} do return false
	path, known := engine.asset_db_get_path(uuid.Identifier(_sg.guid))
	doc := inspector.asset_doc_get(path) if known else nil
	if doc == nil || doc.data.id != typeid_of(sg.Shader_Graph) {
		if !_sg.failed do log.errorf("[ShaderGraph] %s is not a shader graph", path)
		_sg.failed = true
		return false
	}
	_sg.asset = doc
	_sg.graph = (^sg.Shader_Graph)(doc.data.data)
	if rawptr(_sg.graph) != _sg.seen {
		_sg.seen = _sg.graph
		delete(_sg.baseline)
		_sg.baseline = string(undo.capture_json(_sg.graph, typeid_of(sg.Shader_Graph)))
		_sg.touched = false
		_sg.rename = -1
		_sg.cv.sel_link = -1
		if sg.graph_find_node(_sg.graph, i32(_sg.cv.sel)) == nil do _sg.cv.sel = -1
		_sg_regen()
	}
	return true
}

@(editor_window={id="shader_graph", title="Shader Graph", icon="ACCOUNT_TREE", width=1100, height=640, closed=shader_graph_window_closed})
shader_graph_window_draw :: proc(w: ^wnd.Window) {
	// Edits allocate into the shared document, so they use its allocator.
	// The undo stack owns what is pushed to it and frees it with the editor's
	// context allocator, so a step is built with the caller's (_sg_record).
	caller := context.allocator
	context.allocator = inspector.doc_alloc()
	if w.asset == {} {
		im.TextDisabled("Select a .shadergraph in the Project view and press Open Shader Graph.")
		return
	}
	_sg = _sg_instance(w)
	if !_sg_fetch() {
		im.TextDisabled("This file is not a shader graph.")
		return
	}

	_sg_toolbar()
	im.Separator()

	// Blackboard | canvas | GLSL, split by the shared splitter. The side panes
	// keep their widths when the window resizes, and give way to the canvas
	// when the window gets too narrow for all three.
	prefs := &shader_graph_prefs
	show_left := !prefs.hide_blackboard
	show_right := !prefs.hide_glsl
	avail := im.GetContentRegionAvail()
	left_w := show_left ? (prefs.left_w > 0 ? prefs.left_w : _SG_LEFT_W) : 0
	right_w := show_right ? (prefs.right_w > 0 ? prefs.right_w : _SG_RIGHT_W) : 0
	splitters := f32(int(show_left) + int(show_right)) * widgets.SPLITTER_SIZE
	mid_w := avail.x - splitters - left_w - right_w
	if mid_w < _SG_MIN_MID {
		short := _SG_MIN_MID - mid_w
		give := min(short, max(right_w - _SG_MIN_SIDE, 0))
		right_w -= give
		short -= give
		left_w -= min(short, max(left_w - _SG_MIN_SIDE, 0))
		mid_w = avail.x - splitters - left_w - right_w
	}

	if show_left {
		if im.BeginChild("##sg_left", im.Vec2{left_w, avail.y}, {.Borders}) {
			_sg_blackboard()
			im.Spacing()
			_sg_node_panel()
		}
		im.EndChild()
		im.SameLine(0, 0)
		if widgets.splitter("##sg_split_left", true, &left_w, &mid_w, _SG_MIN_SIDE, _SG_MIN_MID) do prefs.left_w = left_w
		im.SameLine(0, 0)
	}

	im.PushStyleVarImVec2(.WindowPadding, im.Vec2{0, 0})
	if im.BeginChild("##sg_mid", im.Vec2{mid_w, avail.y}) {
		_sg_canvas()
	}
	im.EndChild()
	im.PopStyleVar()

	if show_right {
		im.SameLine(0, 0)
		if widgets.splitter("##sg_split_right", true, &mid_w, &right_w, _SG_MIN_MID, _SG_MIN_SIDE) do prefs.right_w = right_w
		im.SameLine(0, 0)
		if im.BeginChild("##sg_right", im.Vec2{0, avail.y}, {.Borders}) {
			_sg_glsl_panel()
		}
		im.EndChild()
	}

	// The add menu opens here, outside the canvas child: the child zeroes the
	// window padding for the canvas, and a popup opened inside it would
	// inherit that.
	if _sg.open_menu {
		_sg.open_menu = false
		im.OpenPopup("##sg_add_node")
	}
	if im.BeginPopup("##sg_add_node") {
		_sg_add_node_menu()
		im.EndPopup()
	}

	io := im.GetIO()
	if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && !io.WantTextInput && !im.IsAnyItemActive() {
		if im.IsKeyPressed(.Delete, false) || im.IsKeyPressed(.Backspace, false) do _sg_delete_selection()
	}

	if _sg.touched && !im.IsAnyItemActive() do _sg_record(caller)
}

// --- Toolbar ------------------------------------------------------------------

@(private = "file")
_sg_toolbar :: proc() {
	// No Save button: the tab menu saves and discards the graph, File/Save
	// saves it with every other file (session/documents.odin).
	im.TextUnformatted(fmt.ctprintf("%s%s", _sg.asset.path, _sg.asset.dirty ? " *" : ""))
	if _sg.notice != "" && im.GetTime() < _sg.notice_until {
		im.SameLine()
		im.TextColoredUnformatted(im.Vec4{1, 0.6, 0.3, 1}, fmt.ctprintf("%s", _sg.notice))
	}

	// The pane toggles, right-aligned.
	style := im.GetStyle()
	w_board := im.CalcTextSize("Blackboard").x + style.FramePadding.x * 2
	w_glsl := im.CalcTextSize("GLSL").x + style.FramePadding.x * 2
	im.SameLine()
	x := im.GetCursorPosX()
	im.SetCursorPosX(max(x + im.GetContentRegionAvail().x - w_board - w_glsl - style.ItemSpacing.x, x))
	_sg_pane_toggle("Blackboard", &shader_graph_prefs.hide_blackboard, "Show the blackboard and the selected node's inputs")
	im.SameLine()
	_sg_pane_toggle("GLSL", &shader_graph_prefs.hide_glsl, "Show the generated shader")
}

// A toolbar button lit while its pane shows. The tint is pushed for the state
// before the click, so the pop matches it.
@(private = "file")
_sg_pane_toggle :: proc(label: cstring, hidden: ^bool, tip: cstring) {
	lit := !hidden^
	if lit do im.PushStyleColorImVec4(.Button, im.GetStyleColorVec4(.ButtonActive)^)
	if im.Button(label) do hidden^ = !hidden^
	if lit do im.PopStyleColor()
	widgets.tooltip(tip)
}

// A save reimports the graph and drops its cached shader, so a material on
// it draws with the new one.
@(provider_install)
_sg_install_document :: proc() {
	inspector.doc_saved_register(typeid_of(sg.Shader_Graph), proc(guid: engine.Asset_GUID, path: string) {
		_ = asset_pipeline.asset_pipeline_import_asset(path)
		engine.shader_unload(guid)
	})
}

// A message shown in the toolbar for a few seconds, and logged.
@(private = "file")
_sg_notify :: proc(msg: string) {
	_sg.notice = msg
	_sg.notice_until = im.GetTime() + 3
	log.warningf("[ShaderGraph] %s", msg)
}

// --- Blackboard ---------------------------------------------------------------

@(private = "file")
_sg_blackboard :: proc() {
	g := _sg.graph
	im.SeparatorText("Blackboard")
	if im.Button("Add") do im.OpenPopup("##sg_add_prop")
	if im.BeginPopup("##sg_add_prop") {
		for name, k in _SG_PROP_KIND_NAMES {
			if im.Selectable(name) {
				def := [4]f32{}
				if k == .Color do def = {1, 1, 1, 1}
				sg.graph_add_property(g, "property", k, def)
				_sg_touch("Add Property")
			}
		}
		im.EndPopup()
	}

	remove := -1
	for &p, i in g.properties {
		im.PushIDInt(i32(i))
		defer im.PopID()

		// The name edits a buffer and lands on leaving the field, so a rename
		// is one step and a half-typed name never collides with another.
		local: [128]u8
		buf := &local
		if _sg.rename == i {
			buf = &_sg.name_buf
		} else {
			copy(local[:len(local) - 1], p.name)
		}
		im.SetNextItemWidth(-28)
		im.InputText("##name", cstring(&buf[0]), len(buf))
		if im.IsItemActivated() {
			_sg.rename = i
			_sg.name_buf = {}
			copy(_sg.name_buf[:len(_sg.name_buf) - 1], p.name)
		}
		if im.IsItemDeactivated() && _sg.rename == i {
			_sg.rename = -1
			_sg_rename_property(&p, string(cstring(&_sg.name_buf[0])))
		}
		im.SameLine()
		if im.Button("x", im.Vec2{20, 0}) do remove = i

		im.SetNextItemWidth(-1)
		if im.BeginCombo("##kind", _SG_PROP_KIND_NAMES[p.kind]) {
			for name, k in _SG_PROP_KIND_NAMES {
				if im.Selectable(name, p.kind == k) && p.kind != k {
					p.kind = k
					_sg_touch("Change Property Kind")
				}
			}
			im.EndCombo()
		}

		im.SetNextItemWidth(-1)
		changed := false
		switch p.kind {
		case .Float:   changed = im.DragFloat("##default", &p.default[0], 0.01)
		case .Vec2:    changed = im.DragFloat2("##default", cast(^[2]f32)&p.default, 0.01)
		case .Vec3:    changed = im.DragFloat3("##default", cast(^[3]f32)&p.default, 0.01)
		case .Vec4:    changed = im.DragFloat4("##default", &p.default, 0.01)
		case .Color:   changed = im.ColorEdit4("##default", &p.default)
		case .Texture: im.TextDisabled("set on the material")
		}
		if changed do _sg_touch("Edit Property Default")
		im.Separator()
	}
	if remove >= 0 {
		name := strings.clone(g.properties[remove].name, context.temp_allocator)
		sg.graph_remove_property(g, name)
		_sg.cv.sel_link = -1
		if sg.graph_find_node(g, i32(_sg.cv.sel)) == nil do _sg.cv.sel = -1
		_sg_touch("Remove Property")
	}
}

// A new name for a property, carried onto every node that reads it. Empty
// or taken names are ignored.
@(private = "file")
_sg_rename_property :: proc(p: ^sg.Graph_Property, name: string) {
	trimmed := strings.trim_space(name)
	if trimmed == "" || trimmed == p.name || sg.graph_find_property(_sg.graph, trimmed) != nil do return
	for &n in _sg.graph.nodes {
		if sg.kind_reads_property(n.kind) && n.property == p.name {
			delete(n.property)
			n.property = strings.clone(trimmed)
		}
	}
	delete(p.name)
	p.name = strings.clone(trimmed)
	_sg_touch("Rename Property")
}

// --- Selected node --------------------------------------------------------------

// The literals of the selected node's unlinked inputs, as drags by port type.
@(private = "file")
_sg_node_panel :: proc() {
	im.SeparatorText("Node")
	n := sg.graph_find_node(_sg.graph, i32(_sg.cv.sel))
	if n == nil {
		im.TextDisabled("Select a node to edit its inputs.")
		return
	}
	def, ok := sg.node_def(n.kind)
	if !ok {
		im.TextDisabled("unknown kind %s", fmt.ctprintf("%s", n.kind))
		return
	}
	im.TextUnformatted(_sg_node_title(n))
	if len(def.inputs) == 0 {
		im.TextDisabled("no inputs")
		return
	}
	for in_port, i in def.inputs {
		if i >= len(n.values) do break
		im.PushIDInt(i32(i))
		defer im.PopID()
		label := fmt.ctprintf("%s", in_port.name)
		if _, linked := sg.graph_input_link(_sg.graph, n.id, i32(i)); linked {
			im.TextDisabled("%s: linked", label)
			continue
		}
		v := &n.values[i]
		changed := false
		im.SetNextItemWidth(-90)
		switch {
		case n.kind == "Color":
			changed = im.ColorEdit4(label, v)
		case in_port.type == .Float:
			changed = im.DragFloat(label, &v[0], 0.01)
		case in_port.type == .Vec2:
			changed = im.DragFloat2(label, cast(^[2]f32)v, 0.01)
		case in_port.type == .Vec3:
			changed = im.DragFloat3(label, cast(^[3]f32)v, 0.01)
		case:
			changed = im.DragFloat4(label, v, 0.01)
		}
		if changed do _sg_touch("Edit Input")
	}
}

// --- Canvas -----------------------------------------------------------------------

@(private = "file")
_sg_canvas :: proc() {
	g := _sg.graph
	cv := &_sg.cv
	if nc.canvas_begin(cv, "##sg_canvas") {
		for l, li in g.links {
			from := sg.graph_find_node(g, l.from_node)
			to := sg.graph_find_node(g, l.to_node)
			if from == nil || to == nil do continue
			fdef, _ := sg.node_def(from.kind)
			p0 := nc.canvas_port_out(cv, from.position, len(fdef.inputs) + int(l.from_port))
			p1 := nc.canvas_port_in(cv, to.position, int(l.to_port))
			col := _SG_PORT_COLS[_sg_out_type(from, int(l.from_port))]
			nc.canvas_link(cv, p0, p1, im.GetColorU32ImVec4(col), index = li)
		}
		for &n in g.nodes {
			rows := _sg_node_rows(&n)
			before := n.position
			nc.canvas_node(cv, int(n.id), &n.position, _sg_node_title(&n), _sg_node_color(&n), rows, false)
			if n.position != before do _sg_touch("Move Node")
		}
	}
	nc.canvas_end(cv)

	edit := cv.edit
	if edit.link_made do _sg_link(edit)
	if edit.context_menu {
		_sg.menu_pos = edit.context_pos
		_sg.open_menu = true // opened by the window, outside this child
	}
}

// A finished link drag: rows map back to ports (inputs first, then outputs).
@(private = "file")
_sg_link :: proc(edit: nc.Canvas_Edit) {
	g := _sg.graph
	from := sg.graph_find_node(g, i32(edit.link_from_node))
	if from == nil do return
	fdef, ok := sg.node_def(from.kind)
	if !ok do return
	from_port := edit.link_from_row - len(fdef.inputs)
	if from_port < 0 do return
	if sg.graph_link(g, from.id, i32(from_port), i32(edit.link_to_node), i32(edit.link_to_row)) {
		_sg_touch("Link")
	} else {
		_sg_notify("Link refused: it would make a cycle")
	}
}

@(private = "file")
_sg_add_node_menu :: proc() {
	g := _sg.graph
	has_surface := false
	for n in g.nodes do if n.kind == sg.SURFACE_KIND do has_surface = true

	for cat in sg.node_categories() {
		if !im.BeginMenu(fmt.ctprintf("%s", cat)) do continue
		for d in sg.NODE_DEFS {
			if d.category != cat do continue
			if sg.kind_reads_property(d.kind) do continue
			if d.kind == sg.SURFACE_KIND && has_surface do continue
			if im.MenuItem(fmt.ctprintf("%s", d.kind)) do _sg_add_node(d.kind, "")
		}
		im.EndMenu()
	}
	if len(g.properties) > 0 do im.Separator()
	for p in g.properties {
		if p.kind == .Texture {
			if im.MenuItem(fmt.ctprintf("Sample Texture: %s", p.name)) do _sg_add_node(sg.SAMPLE_TEXTURE_KIND, p.name)
			if im.MenuItem(fmt.ctprintf("Normal Map: %s", p.name)) do _sg_add_node(sg.NORMAL_MAP_KIND, p.name)
		} else {
			if im.MenuItem(fmt.ctprintf("Property: %s", p.name)) do _sg_add_node(sg.PROPERTY_KIND, p.name)
		}
	}
}

@(private = "file")
_sg_add_node :: proc(kind, property: string) {
	id := sg.graph_add_node(_sg.graph, kind, _sg.menu_pos, property)
	if id == 0 do return
	_sg.cv.sel = int(id)
	_sg.cv.sel_link = -1
	_sg_touch("Add Node")
}

@(private = "file")
_sg_delete_selection :: proc() {
	g := _sg.graph
	cv := &_sg.cv
	if cv.sel_link >= 0 && cv.sel_link < len(g.links) {
		ordered_remove(&g.links, cv.sel_link)
		cv.sel_link = -1
		_sg_touch("Delete Link")
		return
	}
	n := sg.graph_find_node(g, i32(cv.sel))
	if n == nil || n.kind == sg.SURFACE_KIND do return
	sg.graph_remove_node(g, n.id)
	cv.sel = -1
	_sg_touch("Delete Node")
}

@(private = "file")
_sg_node_title :: proc(n: ^sg.Graph_Node) -> cstring {
	switch n.kind {
	case sg.PROPERTY_KIND:       return fmt.ctprintf("%s", n.property)
	case sg.SAMPLE_TEXTURE_KIND: return fmt.ctprintf("Sample %s", n.property)
	case sg.NORMAL_MAP_KIND:     return fmt.ctprintf("Normal Map %s", n.property)
	}
	return fmt.ctprintf("%s", n.kind)
}

@(private = "file")
_sg_node_color :: proc(n: ^sg.Graph_Node) -> im.Vec4 {
	for id in _sg.error_nodes do if id == n.id do return {0.85, 0.25, 0.25, 1}
	def, ok := sg.node_def(n.kind)
	if !ok do return {0.85, 0.25, 0.25, 1}
	switch def.category {
	case "Output":  return {0.35, 0.65, 0.40, 1}
	case "Input":   return {0.30, 0.50, 0.80, 1}
	case "Math":    return {0.55, 0.40, 0.75, 1}
	case "Vector":  return {0.80, 0.55, 0.25, 1}
	case "Channel": return {0.25, 0.62, 0.62, 1}
	case "UV":      return {0.70, 0.65, 0.25, 1}
	}
	return {0.5, 0.5, 0.5, 1}
}

// One row per input (its literal while unlinked, an input port), then one per
// output (an output port).
@(private = "file")
_sg_node_rows :: proc(n: ^sg.Graph_Node) -> []nc.Canvas_Row {
	def, ok := sg.node_def(n.kind)
	if !ok do return nil
	rows := make([dynamic]nc.Canvas_Row, 0, len(def.inputs) + len(def.outputs), context.temp_allocator)
	for in_port, i in def.inputs {
		value: cstring
		if _, linked := sg.graph_input_link(_sg.graph, n.id, i32(i)); !linked && i < len(n.values) {
			value = _sg_literal_text(n.values[i], in_port.type)
		}
		append(&rows, nc.Canvas_Row{
			label = fmt.ctprintf("%s", in_port.name),
			value = value,
			port  = true,
			col   = _SG_PORT_COLS[in_port.type],
		})
	}
	for _, i in def.outputs {
		append(&rows, nc.Canvas_Row{
			value   = fmt.ctprintf("%s", def.outputs[i].name),
			out     = true,
			out_col = _SG_PORT_COLS[_sg_out_type(n, i)],
		})
	}
	return rows[:]
}

// The type an output carries: a Property node's comes from its property.
@(private = "file")
_sg_out_type :: proc(n: ^sg.Graph_Node, port: int) -> sg.Port_Type {
	if n.kind == sg.PROPERTY_KIND {
		if p := sg.graph_find_property(_sg.graph, n.property); p != nil do return sg.prop_port_type(p.kind)
	}
	def, ok := sg.node_def(n.kind)
	if !ok || port >= len(def.outputs) do return .Dyn
	return def.outputs[port].type
}

@(private = "file")
_sg_literal_text :: proc(v: [4]f32, t: sg.Port_Type) -> cstring {
	switch t {
	case .Float: return fmt.ctprintf("%.2f", v[0])
	case .Vec2:  return fmt.ctprintf("%.2f, %.2f", v[0], v[1])
	case .Vec3:  return fmt.ctprintf("%.2f, %.2f, %.2f", v[0], v[1], v[2])
	case .Vec4:  return fmt.ctprintf("%.2f, %.2f, %.2f, %.2f", v[0], v[1], v[2], v[3])
	case .Dyn:
		if v[0] == v[1] && v[1] == v[2] && v[2] == v[3] do return fmt.ctprintf("%.2f", v[0])
		return fmt.ctprintf("%.2f, %.2f, %.2f, %.2f", v[0], v[1], v[2], v[3])
	}
	return nil
}

// --- GLSL ---------------------------------------------------------------------------

@(private = "file")
_sg_glsl_panel :: proc() {
	im.SeparatorText("GLSL")
	for e in _sg.errors {
		im.PushTextWrapPos(0)
		im.TextColoredUnformatted(im.Vec4{1, 0.45, 0.4, 1}, fmt.ctprintf("%s", e))
		im.PopTextWrapPos()
	}
	if _sg.glsl != nil {
		n := len(_sg.glsl)
		im.InputTextMultiline("##glsl", _sg.glsl, uint(n + 1), im.Vec2{-1, -1}, {.ReadOnly})
	}
}

@(private = "file")
_sg_regen :: proc() {
	// The window's own state, on the default allocator whoever calls.
	context.allocator = runtime.default_allocator()
	delete(_sg.glsl)
	_sg.glsl = nil
	for e in _sg.errors do delete(e)
	clear(&_sg.errors)
	clear(&_sg.error_nodes)
	result, ok := sg.generate(_sg.graph)
	if ok do _sg.glsl = strings.clone_to_cstring(result.glsl)
	for e in result.errors {
		append(&_sg.errors, e.node_id != 0 ? fmt.aprintf("node %d: %s", e.node_id, e.message) : strings.clone(e.message))
		if e.node_id != 0 do append(&_sg.error_nodes, e.node_id)
	}
}

// --- Undo ---------------------------------------------------------------------------

@(private = "file")
_sg_touch :: proc(label: string) {
	_sg.touched = true
	_sg.label = label
}

// Records the edits since the last record as one undo step on the asset,
// when they changed the document. The step's two snapshots use
// `undo_allocator`, the one the undo stack frees with. The baseline stays the
// window's own (default allocator).
@(private = "file")
_sg_record :: proc(undo_allocator: runtime.Allocator) {
	_sg.touched = false
	if _sg.graph == nil do return
	tid := typeid_of(sg.Shader_Graph)
	recorded: string
	{
		context.allocator = undo_allocator
		now := undo.capture_json(_sg.graph, tid)
		if string(now) == _sg.baseline {
			delete(now)
			return
		}
		recorded = strings.clone(string(now), runtime.default_allocator())
		before := transmute([]byte)strings.clone(_sg.baseline)
		undo.push_value(undo.get(), undo.make_asset_target(_sg.guid, tid, .File), before, now, _sg.label)
	}
	delete(_sg.baseline, runtime.default_allocator())
	_sg.baseline = recorded
	_sg.asset.dirty = true
	_sg_regen()
}
