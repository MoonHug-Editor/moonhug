package shadergraph

// The node kinds a graph can hold. A node is a GLSL expression per output
// over its inputs: `$0`, `$1`... stand for the inputs, already coerced to the
// port's type (a Dyn port to the node's resolved type). Nodes the generator
// treats specially (Property, Sample Texture, Surface) have no expression.
//
// The table is the palette the editor shows (by category) and the contract
// a .shadergraph file relies on: a kind's inputs keep their order, so a
// saved `values` list stays valid.

Port_Def :: struct {
	name:    string,
	type:    Port_Type,
	default: [4]f32, // an unlinked input's literal
}

Node_Def :: struct {
	kind:     string,
	category: string,
	inputs:   []Port_Def,
	outputs:  []Port_Def,
	glsl:     []string, // one expression per output
}

NODE_DEFS := []Node_Def{
	// --- Output
	{SURFACE_KIND, "Output",
		{{"Albedo", .Vec3, {0.8, 0.8, 0.8, 1}}, {"Alpha", .Float, {1, 0, 0, 0}}, {"Normal", .Vec3, {0, 0, 1, 0}}, {"Emissive", .Vec3, {0, 0, 0, 0}}},
		{}, {}},

	// --- Input
	{PROPERTY_KIND, "Input", {}, {{"Out", .Dyn, {}}}, {}},
	{SAMPLE_TEXTURE_KIND, "Input", {{"UV", .Vec2, {0, 0, 0, 0}}}, {{"RGBA", .Vec4, {}}, {"RGB", .Vec3, {}}, {"A", .Float, {}}}, {}},
	{"Main Texture", "Input", {{"UV", .Vec2, {0, 0, 0, 0}}}, {{"RGBA", .Vec4, {}}, {"RGB", .Vec3, {}}, {"A", .Float, {}}},
		{"srgb_to_linear(texture(tex, $0))", "srgb_to_linear(texture(tex, $0).rgb)", "texture(tex, $0).a"}},
	{"UV", "Input", {}, {{"UV", .Vec2, {}}}, {"frag_uv"}},
	{"Vertex Color", "Input", {}, {{"RGBA", .Vec4, {}}, {"RGB", .Vec3, {}}}, {"frag_color", "frag_color.rgb"}},
	{"World Normal", "Input", {}, {{"Normal", .Vec3, {}}}, {"normalize(frag_normal)"}},
	{"World Position", "Input", {}, {{"Position", .Vec3, {}}}, {"frag_world_pos"}},
	{"View Direction", "Input", {}, {{"Dir", .Vec3, {}}}, {"view_dir()"}},
	{"Camera Position", "Input", {}, {{"Position", .Vec3, {}}}, {"cam_pos.xyz"}},
	{"Float", "Input", {{"Value", .Float, {0, 0, 0, 0}}}, {{"Out", .Float, {}}}, {"$0"}},
	{"Vector 2", "Input", {{"Value", .Vec2, {0, 0, 0, 0}}}, {{"Out", .Vec2, {}}}, {"$0"}},
	{"Vector 3", "Input", {{"Value", .Vec3, {0, 0, 0, 0}}}, {{"Out", .Vec3, {}}}, {"$0"}},
	{"Color", "Input", {{"Value", .Vec4, {1, 1, 1, 1}}}, {{"Out", .Vec4, {}}}, {"$0"}},

	// --- Math
	{"Add", "Math", {{"A", .Dyn, {0, 0, 0, 0}}, {"B", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"($0 + $1)"}},
	{"Subtract", "Math", {{"A", .Dyn, {0, 0, 0, 0}}, {"B", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"($0 - $1)"}},
	{"Multiply", "Math", {{"A", .Dyn, {1, 1, 1, 1}}, {"B", .Dyn, {1, 1, 1, 1}}}, {{"Out", .Dyn, {}}}, {"($0 * $1)"}},
	{"Divide", "Math", {{"A", .Dyn, {1, 1, 1, 1}}, {"B", .Dyn, {1, 1, 1, 1}}}, {{"Out", .Dyn, {}}}, {"($0 / $1)"}},
	{"Lerp", "Math", {{"A", .Dyn, {0, 0, 0, 0}}, {"B", .Dyn, {1, 1, 1, 1}}, {"T", .Float, {0.5, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"mix($0, $1, $2)"}},
	{"Power", "Math", {{"A", .Dyn, {1, 1, 1, 1}}, {"B", .Dyn, {2, 2, 2, 2}}}, {{"Out", .Dyn, {}}}, {"pow($0, $1)"}},
	{"Min", "Math", {{"A", .Dyn, {0, 0, 0, 0}}, {"B", .Dyn, {1, 1, 1, 1}}}, {{"Out", .Dyn, {}}}, {"min($0, $1)"}},
	{"Max", "Math", {{"A", .Dyn, {0, 0, 0, 0}}, {"B", .Dyn, {1, 1, 1, 1}}}, {{"Out", .Dyn, {}}}, {"max($0, $1)"}},
	{"Step", "Math", {{"Edge", .Dyn, {0.5, 0.5, 0.5, 0.5}}, {"X", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"step($0, $1)"}},
	{"Smoothstep", "Math", {{"Edge 0", .Dyn, {0, 0, 0, 0}}, {"Edge 1", .Dyn, {1, 1, 1, 1}}, {"X", .Dyn, {0.5, 0.5, 0.5, 0.5}}}, {{"Out", .Dyn, {}}}, {"smoothstep($0, $1, $2)"}},
	{"One Minus", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"(1.0 - $0)"}},
	{"Saturate", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"clamp($0, 0.0, 1.0)"}},
	{"Absolute", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"abs($0)"}},
	{"Floor", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"floor($0)"}},
	{"Fraction", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"fract($0)"}},
	{"Sine", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"sin($0)"}},
	{"Cosine", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"cos($0)"}},
	{"Negate", "Math", {{"In", .Dyn, {0, 0, 0, 0}}}, {{"Out", .Dyn, {}}}, {"(-$0)"}},

	// --- Vector
	{"Dot", "Vector", {{"A", .Vec3, {0, 0, 1, 0}}, {"B", .Vec3, {0, 0, 1, 0}}}, {{"Out", .Float, {}}}, {"dot($0, $1)"}},
	{"Cross", "Vector", {{"A", .Vec3, {1, 0, 0, 0}}, {"B", .Vec3, {0, 1, 0, 0}}}, {{"Out", .Vec3, {}}}, {"cross($0, $1)"}},
	{"Normalize", "Vector", {{"In", .Vec3, {0, 0, 1, 0}}}, {{"Out", .Vec3, {}}}, {"normalize($0)"}},
	{"Length", "Vector", {{"In", .Vec3, {0, 0, 0, 0}}}, {{"Out", .Float, {}}}, {"length($0)"}},
	{"Distance", "Vector", {{"A", .Vec3, {0, 0, 0, 0}}, {"B", .Vec3, {0, 0, 0, 0}}}, {{"Out", .Float, {}}}, {"distance($0, $1)"}},
	{"Fresnel", "Vector", {{"Normal", .Vec3, {0, 0, 1, 0}}, {"View Dir", .Vec3, {0, 0, 1, 0}}, {"Power", .Float, {3, 0, 0, 0}}}, {{"Out", .Float, {}}},
		{"pow(1.0 - clamp(dot(normalize($0), normalize($1)), 0.0, 1.0), $2)"}},
	{"Reflect", "Vector", {{"In", .Vec3, {0, 0, 1, 0}}, {"Normal", .Vec3, {0, 0, 1, 0}}}, {{"Out", .Vec3, {}}}, {"reflect($0, $1)"}},

	// --- Channel
	{"Split", "Channel", {{"In", .Vec4, {0, 0, 0, 0}}}, {{"R", .Float, {}}, {"G", .Float, {}}, {"B", .Float, {}}, {"A", .Float, {}}},
		{"$0.x", "$0.y", "$0.z", "$0.w"}},
	{"Combine", "Channel", {{"R", .Float, {0, 0, 0, 0}}, {"G", .Float, {0, 0, 0, 0}}, {"B", .Float, {0, 0, 0, 0}}, {"A", .Float, {1, 0, 0, 0}}},
		{{"RGBA", .Vec4, {}}, {"RGB", .Vec3, {}}}, {"vec4($0, $1, $2, $3)", "vec3($0, $1, $2)"}},
	{"Swizzle XY", "Channel", {{"In", .Vec4, {0, 0, 0, 0}}}, {{"Out", .Vec2, {}}}, {"$0.xy"}},
	{"Swizzle XYZ", "Channel", {{"In", .Vec4, {0, 0, 0, 0}}}, {{"Out", .Vec3, {}}}, {"$0.xyz"}},

	// --- UV
	{"Tiling And Offset", "UV", {{"UV", .Vec2, {0, 0, 0, 0}}, {"Tiling", .Vec2, {1, 1, 0, 0}}, {"Offset", .Vec2, {0, 0, 0, 0}}}, {{"Out", .Vec2, {}}}, {"($0 * $1 + $2)"}},
}

node_def :: proc(kind: string) -> (Node_Def, bool) {
	for d in NODE_DEFS do if d.kind == kind do return d, true
	return {}, false
}

// The categories in palette order, each once.
node_categories :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	outer: for d in NODE_DEFS {
		for c in out do if c == d.category do continue outer
		append(&out, d.category)
	}
	return out[:]
}

// The port type a property's node outputs.
prop_port_type :: proc(kind: Prop_Kind) -> Port_Type {
	switch kind {
	case .Float:   return .Float
	case .Vec2:    return .Vec2
	case .Vec3:    return .Vec3
	case .Vec4, .Color: return .Vec4
	case .Texture: return .Vec4 // a Sample Texture node's RGBA
	}
	return .Float
}
