// Bloom, passes 2 and 3: a 9-tap gaussian along `dir` (one texel in uv,
// horizontal then vertical), each on the previous pass's output.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // xy = blur direction in uv (one texel), zw unused
};

void main() {
    const float w[5] = float[5](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);
    vec2 step = params.xy;
    vec3 c = texture(tex, frag_uv).rgb * w[0];
    for (int i = 1; i < 5; ++i) {
        c += texture(tex, frag_uv + step * float(i)).rgb * w[i];
        c += texture(tex, frag_uv - step * float(i)).rgb * w[i];
    }
    out_color = vec4(c, 1.0);
}
