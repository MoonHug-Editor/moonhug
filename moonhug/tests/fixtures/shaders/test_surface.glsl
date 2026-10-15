// A surface shader for the importer tests: surface() only, compiled inside
// the template, which declares the shadow map and the environment cubes.

layout(set = 3, binding = 1) uniform MaterialUBO {
    float tint_strength;
};

void surface(inout Surface s) {
    s.albedo *= tint_strength;
}
