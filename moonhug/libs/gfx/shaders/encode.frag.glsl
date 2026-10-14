// Encodes a linear image to sRGB for a Display target: the window, the
// editor's views, previews. The exact piecewise curve, alpha unchanged.
// SDL_GPU SPIR-V convention: fragment samplers in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

vec3 linear_to_srgb(vec3 c) {
    c = max(c, vec3(0.0));
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(lessThanEqual(c, vec3(0.0031308))));
}

void main() {
    vec4 c = texture(tex, frag_uv);
    out_color = vec4(linear_to_srgb(c.rgb), c.a);
}
