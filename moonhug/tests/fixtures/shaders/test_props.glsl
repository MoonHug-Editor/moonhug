#version 450
layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(set = 2, binding = 0) uniform sampler2D tex;
layout(set = 3, binding = 1) uniform MaterialUBO {
    float mix_amount;
    vec4  rim_color;
};
layout(location = 0) out vec4 out_color;
void main() {
    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = mix(base, rim_color, mix_amount) + vec4(frag_normal * 0.0, 0.0);
}
