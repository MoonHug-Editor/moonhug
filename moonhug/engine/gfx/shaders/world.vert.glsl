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

// tint: batch draws bake color into vertices and push white; mesh draws
// push their material color here (mesh vertex color is white from import).
layout(set = 1, binding = 0) uniform UBO {
    mat4 view_proj;
    mat4 model;
    vec4 tint;
};

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;
layout(location = 2) out vec3 frag_normal;

void main() {
    gl_Position = view_proj * model * vec4(in_position, 1.0);
    frag_uv     = in_uv;
    frag_color  = in_color * tint;
    // mat3(model) is wrong under non-uniform scale (needs inverse-transpose);
    // accepted for the built-in lit shader, normals renormalize in fragment.
    frag_normal = mat3(model) * in_normal;
}
