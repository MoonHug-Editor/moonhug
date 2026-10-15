// A depth texture as grey, for the Render Pipeline window: near white, far
// and empty black. mode.x 0 reads depth as linear (an orthographic shadow
// map), 1 as a perspective camera's, spread out logarithmically, since its
// depth bunches near 1. Fetched, not filtered: not every GPU filters depth.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D depth;

layout(set = 3, binding = 1) uniform Params {
    vec4 mode;
};

void main() {
    ivec2 size = textureSize(depth, 0);
    float d = texelFetch(depth, clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1), 0).r;
    float v = mode.x < 0.5 ? 1.0 - d : 1.0 - clamp(-log2(max(1.0 - d, 1e-7)) / 16.0, 0.0, 1.0);
    out_color = vec4(vec3(v), 1.0);
}
