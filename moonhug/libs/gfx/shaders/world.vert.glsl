// The one world vertex shader (shared by every built-in fragment shader):
// transforms vertices by view_proj * model and passes uv, vertex color and
// world-space normal through. The model matrix and tint are per instance
// (vertex buffer slot 1, one entry per drawn object): an instanced mesh draw
// reads one entry per instance, a batch draw reads the identity entry (its
// vertices are already world-space, its colors baked in).
//
// SDL_GPU SPIR-V convention: vertex uniform buffers live in set 1.
#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;
layout(location = 4) in vec4 in_tangent; // xyz direction of +u, w bitangent sign; zero = none
layout(location = 10) in vec2 in_uv2;    // the second texture coordinate set; zero = none

// Per instance: the model matrix's four columns, then the tint. Batch draws
// bake color into vertices and read a white tint; mesh draws carry their
// material color here (mesh vertex color is white from import). Both arrive
// sRGB as authored and leave as linear light: every pass gfx draws is linear
// (gfx.odin, Target_Format).
layout(location = 5) in vec4 in_model0;
layout(location = 6) in vec4 in_model1;
layout(location = 7) in vec4 in_model2;
layout(location = 8) in vec4 in_model3;
layout(location = 9) in vec4 in_tint;

layout(set = 1, binding = 0) uniform UBO {
    mat4 view_proj;
    // x = how far toward the camera, as a fraction of the vertex's distance,
    // the depth of a depth-tested line moves (gfx LINE_DEPTH_PULL), 0 for
    // everything else.
    vec4 vert_params;
};

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out vec3 frag_normal;
layout(location = 3) out vec3 frag_world_pos;
// World-space tangent and the bitangent sign, for normal maps (surface.glsl
// perturb_normal). Zero when the vertex has none.
layout(location = 4) out vec4 frag_tangent;
layout(location = 5) out vec2 frag_uv2;

// The same vertex gives the same depth in every pipeline: a depth prepass
// and the shading pass after it compare equal. A depth-tested line is the one
// exception: its depth moves toward the camera on purpose (vert_params.x).
invariant gl_Position;

// A color brighter than 1 is an sRGB color times a linear intensity, as in
// gfx.srgb_to_linear.
vec3 srgb_to_linear(vec3 c) {
    float m = max(max(c.r, c.g), max(c.b, 1.0));
    c /= m;
    return m * mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);
    vec4 world = model * vec4(in_position, 1.0);
    gl_Position = view_proj * world;
    // A line lying on a surface (a gizmo on a mesh, the grid on a floor) has
    // the surface's depths, and lines rasterize a little differently from
    // triangles, so the two fight. Moving the line's depth a small fraction of
    // its distance toward the camera wins every such tie at any distance,
    // with its place on screen unchanged: to first order, z - f * (w - z) is
    // the clip depth of the point f of its view distance closer, for a
    // perspective and an orthographic camera alike.
    gl_Position.z -= vert_params.x * (gl_Position.w - gl_Position.z);
    frag_uv     = in_uv;
    frag_uv2    = in_uv2;
    frag_color  = vec4(srgb_to_linear(in_color.rgb) * srgb_to_linear(in_tint.rgb), in_color.a * in_tint.a);
    // mat3(model) is wrong under non-uniform scale (needs inverse-transpose);
    // accepted for the built-in lit shader, normals renormalize in fragment.
    frag_normal = mat3(model) * in_normal;
    // World-space position for view-dependent shading (specular, fresnel) —
    // fragment shaders that don't declare the input simply ignore it.
    frag_world_pos = world.xyz;
    // A mirrored model turns the tangent frame's handedness around: the
    // bitangent sign follows it, so normal maps tilt the right way.
    float mirror = determinant(mat3(model)) < 0.0 ? -1.0 : 1.0;
    frag_tangent = vec4(mat3(model) * in_tangent.xyz, in_tangent.w * mirror);
}
