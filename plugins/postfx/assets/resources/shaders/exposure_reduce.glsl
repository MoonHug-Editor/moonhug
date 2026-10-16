// Auto exposure, the reduction: each output texel the average of the 4 x 4
// input texels under it, red and green, in four filtered taps that each fall
// between four texels. 256 -> 64 -> 16 -> 4 -> 1: the last holds the
// weighted log2 luminance's average and the weights' (exposure_luminance).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // unused
};

void main() {
    vec2 t = 1.0 / vec2(textureSize(tex, 0));
    vec2 s = texture(tex, frag_uv + vec2(-1.0, -1.0) * t).rg
           + texture(tex, frag_uv + vec2( 1.0, -1.0) * t).rg
           + texture(tex, frag_uv + vec2(-1.0,  1.0) * t).rg
           + texture(tex, frag_uv + vec2( 1.0,  1.0) * t).rg;
    out_color = vec4(s * 0.25, 0.0, 1.0);
}
