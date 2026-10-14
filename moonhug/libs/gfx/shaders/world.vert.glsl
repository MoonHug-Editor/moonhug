// The one world vertex shader (shared by every built-in fragment shader):
// transforms vertices by view_proj * model and passes uv, vertex color and
// world-space normal through. Batch draws push model = identity (their
// vertices are already world-space); mesh draws push their model matrix.
//
// SDL_GPU SPIR-V convention: vertex uniform buffers live in set 1.
#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;
layout(location = 4) in vec4 in_tangent; // xyz direction of +u, w bitangent sign; zero = none

// tint: batch draws bake color into vertices and push white; mesh draws
// push their material color here (mesh vertex color is white from import).
// Both arrive sRGB as authored and leave as linear light: every pass gfx
// draws is linear (gfx.odin, Target_Format).
layout(set = 1, binding = 0) uniform UBO {
    mat4 view_proj;
    mat4 model;
    vec4 tint;
};

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out vec3 frag_normal;
layout(location = 3) out vec3 frag_world_pos;
// World-space tangent and the bitangent sign, for normal maps (surface.glsl
// perturb_normal). Zero when the vertex has none.
layout(location = 4) out vec4 frag_tangent;

// A color brighter than 1 is an sRGB color times a linear intensity, as in
// gfx.srgb_to_linear.
vec3 srgb_to_linear(vec3 c) {
    float m = max(max(c.r, c.g), max(c.b, 1.0));
    c /= m;
    return m * mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    vec4 world = model * vec4(in_position, 1.0);
    gl_Position = view_proj * world;
    frag_uv     = in_uv;
    frag_color  = vec4(srgb_to_linear(in_color.rgb) * srgb_to_linear(tint.rgb), in_color.a * tint.a);
    // mat3(model) is wrong under non-uniform scale (needs inverse-transpose);
    // accepted for the built-in lit shader, normals renormalize in fragment.
    frag_normal = mat3(model) * in_normal;
    // World-space position for view-dependent shading (specular, fresnel) —
    // fragment shaders that don't declare the input simply ignore it.
    frag_world_pos = world.xyz;
    frag_tangent = vec4(mat3(model) * in_tangent.xyz, in_tangent.w);
}
