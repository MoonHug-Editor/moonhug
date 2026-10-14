// World-space normal as color, the scene view's Normals mode. Same inputs as
// world.frag (the shared world vertex stage), the texture is bound but unused.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

void main() {
    vec3 n = normalize(frag_normal);
    out_color = vec4(n * 0.5 + 0.5, 1.0);
}
