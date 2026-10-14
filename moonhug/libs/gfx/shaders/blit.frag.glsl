// Copies a texture to the target: the built-in fullscreen shader and the
// identity tonemap. SDL_GPU SPIR-V convention: fragment samplers in set 2,
// fragment uniform buffers in set 3 (none here).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

void main() {
    out_color = texture(tex, frag_uv);
}
