package shadergraph_tests

// The graph document and its code generation (plugins/shadergraph/docs/ShaderGraph.md).
// Compiling the GLSL needs the toolchain and a GPU, which the editor
// exercises through the importer.

import "core:fmt"
import "core:strings"
import "core:testing"
import sg "moonhug:packages/shadergraph"

// The rim.glsl sample as a graph: emissive = rim_color.rgb * rim_color.w *
// fresnel(normal, view, rim_power).
@(private)
_rim_graph :: proc() -> sg.Shader_Graph {
	g: sg.Shader_Graph
	sg.reset_Shader_Graph(&g)
	sg.graph_add_property(&g, "rim_color", .Color, {1, 0.8, 0.4, 1})
	sg.graph_add_property(&g, "rim_power", .Float, {3, 0, 0, 0})
	color := sg.graph_add_node(&g, sg.PROPERTY_KIND, {0, 0}, "rim_color")
	power := sg.graph_add_node(&g, sg.PROPERTY_KIND, {0, 40}, "rim_power")
	normal := sg.graph_add_node(&g, "World Normal", {0, 80})
	view := sg.graph_add_node(&g, "View Direction", {0, 120})
	fresnel := sg.graph_add_node(&g, "Fresnel", {200, 80})
	split := sg.graph_add_node(&g, "Split", {200, 0})
	strength := sg.graph_add_node(&g, "Multiply", {400, 40}) // rim * w
	glow := sg.graph_add_node(&g, "Multiply", {600, 40})     // rgb * strength
	surface := g.nodes[0].id
	assert(g.nodes[0].kind == sg.SURFACE_KIND)
	assert(sg.graph_link(&g, normal, 0, fresnel, 0))
	assert(sg.graph_link(&g, view, 0, fresnel, 1))
	assert(sg.graph_link(&g, power, 0, fresnel, 2))
	assert(sg.graph_link(&g, color, 0, split, 0))
	assert(sg.graph_link(&g, fresnel, 0, strength, 0))
	assert(sg.graph_link(&g, split, 3, strength, 1))
	assert(sg.graph_link(&g, color, 0, glow, 0))
	assert(sg.graph_link(&g, strength, 0, glow, 1))
	assert(sg.graph_link(&g, glow, 0, surface, 3))
	return g
}

@(test)
test_codegen_rim_graph :: proc(t: ^testing.T) {
	g := _rim_graph()
	defer sg.cleanup_Shader_Graph(&g)
	r, ok := sg.generate(&g)
	testing.expect(t, ok, "codegen reports no error")
	testing.expect_value(t, len(r.errors), 0)
	glsl := r.glsl
	testing.expect(t, strings.contains(glsl, "layout(set = 3, binding = 1) uniform MaterialUBO {\n    vec4 rim_color;\n    float rim_power;\n};"), "the property block in blackboard order")
	testing.expect(t, strings.contains(glsl, "void surface(inout Surface s) {"), "the surface function")
	testing.expect(t, strings.contains(glsl, "pow(1.0 - clamp(dot(normalize("), "the fresnel expression")
	testing.expect(t, strings.contains(glsl, "s.emissive = "), "the master's emissive input is assigned")
	testing.expect(t, !strings.contains(glsl, "s.albedo"), "an unlinked master input keeps the template preset")
	// The color (vec4) times the float strength: the float spreads, the
	// product is a vec4, and the vec3 field takes its xyz.
	testing.expect(t, strings.contains(glsl, "s.emissive = n") && strings.contains(glsl, ".xyz;"), "a vec4 result is coerced to the vec3 field")
}

@(test)
test_codegen_empty_graph_is_the_lit_shader :: proc(t: ^testing.T) {
	g: sg.Shader_Graph
	sg.reset_Shader_Graph(&g)
	defer sg.cleanup_Shader_Graph(&g)
	r, ok := sg.generate(&g)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(r.glsl, "void surface(inout Surface s) {\n}"), "an empty surface()")
	testing.expect(t, !strings.contains(r.glsl, "MaterialUBO"), "no property block without properties")
}

@(test)
test_codegen_skips_unreachable_nodes_and_coerces :: proc(t: ^testing.T) {
	g: sg.Shader_Graph
	sg.reset_Shader_Graph(&g)
	defer sg.cleanup_Shader_Graph(&g)
	surface := g.nodes[0].id
	stray := sg.graph_add_node(&g, "Sine", {0, 0})
	f := sg.graph_add_node(&g, "Float", {0, 0})
	g.nodes[len(g.nodes) - 1].values[0] = {0.25, 0, 0, 0}
	testing.expect(t, sg.graph_link(&g, f, 0, surface, 0), "a float feeds the vec3 albedo")
	r, ok := sg.generate(&g)
	testing.expect(t, ok)
	testing.expect(t, !strings.contains(r.glsl, "sin("), "the stray node is not emitted")
	testing.expect(t, strings.contains(r.glsl, "float n"), "the float node is emitted")
	testing.expect(t, strings.contains(r.glsl, "s.albedo = vec3(n"), "the float spreads to the vec3 field")
	_ = stray
}

@(test)
test_graph_link_rejects_cycles_and_replaces_inputs :: proc(t: ^testing.T) {
	g: sg.Shader_Graph
	sg.reset_Shader_Graph(&g)
	defer sg.cleanup_Shader_Graph(&g)
	a := sg.graph_add_node(&g, "Add", {0, 0})
	b := sg.graph_add_node(&g, "Add", {0, 0})
	testing.expect(t, sg.graph_link(&g, a, 0, b, 0))
	testing.expect(t, !sg.graph_link(&g, b, 0, a, 0), "b -> a would close a cycle")
	c := sg.graph_add_node(&g, "Float", {0, 0})
	testing.expect(t, sg.graph_link(&g, c, 0, b, 0), "a new link replaces the old one on the same input")
	n := 0
	for l in g.links do if l.to_node == b && l.to_port == 0 do n += 1
	testing.expect_value(t, n, 1)
	sg.graph_remove_node(&g, c)
	_, still := sg.graph_input_link(&g, b, 0)
	testing.expect(t, !still, "removing a node drops its links")
}

@(test)
test_graph_file_round_trip :: proc(t: ^testing.T) {
	g := _rim_graph()
	defer sg.cleanup_Shader_Graph(&g)
	path := "moonhug/tests/fixtures/_test_shader_graph.shadergraph"
	testing.expect(t, sg.graph_save_file(&g, path))
	loaded, ok := sg.graph_load_file(path)
	testing.expect(t, ok)
	defer sg.cleanup_Shader_Graph(&loaded)
	testing.expect_value(t, len(loaded.nodes), len(g.nodes))
	testing.expect_value(t, len(loaded.links), len(g.links))
	testing.expect_value(t, len(loaded.properties), 2)
	r1, _ := sg.generate(&g)
	r2, _ := sg.generate(&loaded)
	testing.expect(t, r1.glsl == r2.glsl, "the reloaded graph generates the same shader")
}

@(test)
test_property_identifier :: proc(t: ^testing.T) {
	testing.expect_value(t, sg.prop_identifier("rim_color"), "rim_color")
	testing.expect_value(t, sg.prop_identifier("Rim Color 2"), "Rim_Color_2")
	testing.expect_value(t, sg.prop_identifier("2nd"), "_nd")
	testing.expect_value(t, sg.prop_identifier(""), "prop")
}

// A Normal Map node reads its texture as data (no sRGB decode), turns it to
// world space through the template's perturb_normal, and an unlinked UV is
// the mesh's uvs. A Sample Texture node decodes its color.
@(test)
test_codegen_normal_map_and_texture_uvs :: proc(t: ^testing.T) {
	g: sg.Shader_Graph
	sg.reset_Shader_Graph(&g)
	defer sg.cleanup_Shader_Graph(&g)
	surface := g.nodes[0].id
	sg.graph_add_property(&g, "bumps", .Texture)
	sg.graph_add_property(&g, "base", .Texture)
	nm := sg.graph_add_node(&g, sg.NORMAL_MAP_KIND, {0, 0}, "bumps")
	tex := sg.graph_add_node(&g, sg.SAMPLE_TEXTURE_KIND, {0, 0}, "base")
	testing.expect(t, sg.graph_link(&g, nm, 0, surface, 2), "the normal map feeds the Surface's Normal")
	testing.expect(t, sg.graph_link(&g, tex, 1, surface, 0), "the texture's RGB feeds the albedo")
	r, ok := sg.generate(&g)
	testing.expect(t, ok)
	testing.expect_value(t, len(r.errors), 0)
	bumps, base := sg.prop_identifier("bumps"), sg.prop_identifier("base")
	testing.expect(t, strings.contains(r.glsl, fmt.tprintf("perturb_normal(texture(%s, frag_uv).xyz * 2.0 - 1.0, 1.000000)", bumps)), "the normal map: data, unpacked, mesh uvs")
	testing.expect(t, strings.contains(r.glsl, fmt.tprintf("srgb_to_linear(texture(%s, frag_uv))", base)), "the color texture: decoded, mesh uvs")
	testing.expect(t, strings.contains(r.glsl, "s.normal = n"), "the Surface's Normal is set")
}
