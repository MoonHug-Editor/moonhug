// Built-in "lit" shader: texture * color with a fixed directional lambert
// term (hemisphere-ish: ambient floor + diffuse). Light direction is baked —
// light components are a follow-up (docs/Materials.md).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

const vec3 LIGHT_DIR = normalize(vec3(-0.5, -1.0, -0.4)); // world, toward scene
const float AMBIENT  = 0.35;

void main() {
    vec3 n = normalize(frag_normal);
    float diffuse = max(dot(n, -LIGHT_DIR), 0.0);
    float light = AMBIENT + (1.0 - AMBIENT) * diffuse;
    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb * light, base.a);
}
