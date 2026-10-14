// texture * vertex color. Untextured draws bind the 1x1 white texture.
// The texture is color data stored as sRGB, decoded to linear here (the
// vertex color arrives linear from world.vert).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    vec4 t = texture(tex, frag_uv);
    out_color = vec4(srgb_to_linear(t.rgb), t.a) * frag_color;
}
