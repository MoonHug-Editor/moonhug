package shadergraph

// Shader Graph: a node graph that compiles to a surface shader
// (plugins/engine/docs/Materials.md "Surface shaders", docs/ShaderGraph.md).
//
// The asset is a `.shadergraph` JSON file: the blackboard (properties), the
// nodes, the links between their ports, and one Surface node whose inputs
// are the template's `Surface` fields. The importer (editor/) runs codegen
// and compiles the result exactly like a hand-written `.glsl`, so a Material
// names a `.shadergraph` the way it names a `.glsl`, and the two render the
// same.
//
// This package holds the document and the code generation, nothing of the
// editor: the window, the canvas and undo live in editor/.

import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:strings"
import "moonhug:libs/serialization"
import "moonhug:packages/engine"

// What flows through a port. Dyn ports take the largest type linked into the
// node (a float times a color is a color), float when nothing is linked.
Port_Type :: enum u8 {
	Float,
	Vec2,
	Vec3,
	Vec4,
	Dyn,
}

// A blackboard entry: a material property the generated shader declares.
Prop_Kind :: enum u8 {
	Float,
	Vec2,
	Vec3,
	Vec4,
	Color,   // a vec4 the material inspector shows as a color
	Texture, // a sampler2D, a texture row on the material
}

Graph_Property :: struct {
	name:    string,
	kind:    Prop_Kind,
	default: [4]f32, // the value a material starts from (unused for Texture)
}

// One node. `kind` names a Node_Def (nodes.odin). `property` names the
// blackboard entry for Property and Sample Texture nodes. `values` holds the
// literal of each input port while nothing is linked into it.
Graph_Node :: struct {
	id:       i32,
	kind:     string,
	position: [2]f32,
	property: string,
	values:   [dynamic][4]f32,
}

// An edge from an output port to an input port, by node id and port index.
Graph_Link :: struct {
	from_node: i32,
	from_port: i32,
	to_node:   i32,
	to_port:   i32,
}

@(typ_guid={guid = "63d79718-e863-4004-a6e3-d8e372be9476", menu_assets_create = {menu_name = "Shader Graph", file_name = "New Shader Graph.shadergraph", order = -5}})
Shader_Graph :: struct {
	properties: [dynamic]Graph_Property,
	nodes:      [dynamic]Graph_Node,
	links:      [dynamic]Graph_Link,
	next_id:    i32,
}

// The kind of the one output node, and of the node every property gets.
SURFACE_KIND        :: "Surface"
PROPERTY_KIND       :: "Property"
SAMPLE_TEXTURE_KIND :: "Sample Texture"

// A new graph: one Surface node, no properties. What the Create menu writes.
reset_Shader_Graph :: proc(g: ^Shader_Graph) {
	cleanup_Shader_Graph(g)
	g.next_id = 1
	graph_add_node(g, SURFACE_KIND, {520, 160})
}

cleanup_Shader_Graph :: proc(g: ^Shader_Graph) {
	for p in g.properties do delete(p.name)
	delete(g.properties)
	for &n in g.nodes do node_destroy(&n)
	delete(g.nodes)
	delete(g.links)
	g^ = {}
}

node_destroy :: proc(n: ^Graph_Node) {
	delete(n.kind)
	delete(n.property)
	delete(n.values)
	n^ = {}
}

// Adds a node of `kind` with its inputs' default literals. Returns its id,
// 0 for an unknown kind.
graph_add_node :: proc(g: ^Shader_Graph, kind: string, position: [2]f32, property := "") -> i32 {
	def, ok := node_def(kind)
	if !ok do return 0
	if g.next_id < 1 do g.next_id = 1
	n := Graph_Node{
		id       = g.next_id,
		kind     = strings_clone(kind),
		position = position,
		property = strings_clone(property),
		values   = make([dynamic][4]f32),
	}
	for in_port in def.inputs do append(&n.values, in_port.default)
	append(&g.nodes, n)
	g.next_id += 1
	return n.id
}

graph_find_node :: proc(g: ^Shader_Graph, id: i32) -> ^Graph_Node {
	for &n in g.nodes do if n.id == id do return &n
	return nil
}

// Removes a node and every link touching it.
graph_remove_node :: proc(g: ^Shader_Graph, id: i32) {
	for i := len(g.links) - 1; i >= 0; i -= 1 {
		l := g.links[i]
		if l.from_node == id || l.to_node == id do ordered_remove(&g.links, i)
	}
	for &n, i in g.nodes {
		if n.id == id {
			node_destroy(&n)
			ordered_remove(&g.nodes, i)
			return
		}
	}
}

// Links an output port to an input port, replacing whatever fed that input.
// False when either end does not exist or the link would make a cycle.
graph_link :: proc(g: ^Shader_Graph, from_node, from_port, to_node, to_port: i32) -> bool {
	from := graph_find_node(g, from_node)
	to := graph_find_node(g, to_node)
	if from == nil || to == nil || from == to do return false
	fdef, fok := node_def(from.kind)
	tdef, tok := node_def(to.kind)
	if !fok || !tok do return false
	if int(from_port) >= len(fdef.outputs) || int(to_port) >= len(tdef.inputs) do return false
	if graph_reaches(g, to_node, from_node) do return false // `from` depends on `to`: a cycle
	graph_unlink_input(g, to_node, to_port)
	append(&g.links, Graph_Link{from_node = from_node, from_port = from_port, to_node = to_node, to_port = to_port})
	return true
}

// Removes the link feeding an input port, if any.
graph_unlink_input :: proc(g: ^Shader_Graph, to_node, to_port: i32) {
	for l, i in g.links {
		if l.to_node == to_node && l.to_port == to_port {
			ordered_remove(&g.links, i)
			return
		}
	}
}

// The link feeding an input port, if any.
graph_input_link :: proc(g: ^Shader_Graph, to_node, to_port: i32) -> (Graph_Link, bool) {
	for l in g.links do if l.to_node == to_node && l.to_port == to_port do return l, true
	return {}, false
}

// True when `from`'s outputs reach `to` through links (so linking to -> from
// would close a cycle).
graph_reaches :: proc(g: ^Shader_Graph, from, to: i32) -> bool {
	if from == to do return true
	for l in g.links {
		if l.from_node == from && graph_reaches(g, l.to_node, to) do return true
	}
	return false
}

graph_find_property :: proc(g: ^Shader_Graph, name: string) -> ^Graph_Property {
	for &p in g.properties do if p.name == name do return &p
	return nil
}

// Adds a blackboard entry. A name already taken gets a numeric suffix.
graph_add_property :: proc(g: ^Shader_Graph, name: string, kind: Prop_Kind, default: [4]f32 = {}) -> string {
	final := strings_clone(name)
	for i := 2; graph_find_property(g, final) != nil; i += 1 {
		delete(final)
		final = fmt_tprintf_clone("%s_%d", name, i)
	}
	append(&g.properties, Graph_Property{name = final, kind = kind, default = default})
	return final
}

// Removes a property and the nodes that name it.
graph_remove_property :: proc(g: ^Shader_Graph, name: string) {
	for i := len(g.nodes) - 1; i >= 0; i -= 1 {
		n := g.nodes[i]
		if (n.kind == PROPERTY_KIND || n.kind == SAMPLE_TEXTURE_KIND) && n.property == name do graph_remove_node(g, n.id)
	}
	for p, i in g.properties {
		if p.name == name {
			delete(p.name)
			ordered_remove(&g.properties, i)
			return
		}
	}
}

// --- File ------------------------------------------------------------------

// Reads a .shadergraph. The graph owns what it holds (cleanup_Shader_Graph).
graph_load_file :: proc(path: string) -> (g: Shader_Graph, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, false
	return graph_parse(data)
}

graph_parse :: proc(data: []u8) -> (g: Shader_Graph, ok: bool) {
	if json.unmarshal(data, &g, .JSON, context.allocator) != nil {
		cleanup_Shader_Graph(&g)
		return {}, false
	}
	return g, true
}

// Writes the asset in the shape the Create menu writes (serialization).
graph_save_file :: proc(g: ^Shader_Graph, path: string, guid: engine.Asset_GUID) -> bool {
	return serialization.write_asset_to_path(path, uuid.Identifier(guid), g^)
}

@(private = "file")
strings_clone :: proc(s: string) -> string {
	return strings.clone(s)
}

@(private = "file")
fmt_tprintf_clone :: proc(format: string, args: ..any) -> string {
	return strings.clone(fmt.tprintf(format, ..args))
}
