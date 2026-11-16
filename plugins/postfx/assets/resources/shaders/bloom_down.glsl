// Bloom, the downsample chain: each level half the size of the one before,
// filtered from 13 taps of it, the pattern of Jimenez's "Next Generation
// Post Processing in Call of Duty: Advanced Warfare" (SIGGRAPH 2014): five
// overlapping 2x2 boxes, the middle one weighted 0.5 and the four corner
// ones 0.125 each. Wide and smooth, so the glow does not shimmer as the
// image moves.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // xy = one texel of the source level in uv, zw unused
};

vec3 tap(float x, float y) {
    return texture(tex, frag_uv + vec2(x, y) * params.xy).rgb;
}

void main() {
    vec3 a = tap(-2.0, 2.0), b = tap(0.0, 2.0), c = tap(2.0, 2.0);
    vec3 d = tap(-2.0, 0.0), e = tap(0.0, 0.0), f = tap(2.0, 0.0);
    vec3 g = tap(-2.0, -2.0), h = tap(0.0, -2.0), i = tap(2.0, -2.0);
    vec3 j = tap(-1.0, 1.0), k = tap(1.0, 1.0);
    vec3 l = tap(-1.0, -1.0), m = tap(1.0, -1.0);
    vec3 col = e * 0.125;
    col += (a + c + g + i) * 0.03125;
    col += (b + d + f + h) * 0.0625;
    col += (j + k + l + m) * 0.125;
    out_color = vec4(col, 1.0);
}
