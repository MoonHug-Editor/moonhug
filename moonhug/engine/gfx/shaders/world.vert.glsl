// The one world shader: transforms batched/mesh vertices by view_proj and
// passes uv + vertex color through. Normal is declared to match Vertex but
// unused until lighting lands.
//
// SDL_GPU SPIR-V convention: vertex uniform buffers live in set 1.
#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_color;

// tint: batch draws bake color into vertices and push white; mesh draws
// push their color here (mesh vertex color is white from import).
layout(set = 1, binding = 0) uniform UBO {
    mat4 view_proj;
    vec4 tint;
};

layout(location = 0) out vec2 frag_uv;
layout(location = 1) out vec4 frag_color;

void main() {
    gl_Position = view_proj * vec4(in_position, 1.0);
    frag_uv     = in_uv;
    frag_color  = in_color * tint;
}
