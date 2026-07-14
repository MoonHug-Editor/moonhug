// Fixture for multi-texture reflection: samplers past binding 0 become
// named Material texture rows.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;
layout(set = 2, binding = 1) uniform sampler2D detail_tex;
layout(set = 2, binding = 2) uniform sampler2D mask_tex;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 base = texture(tex, frag_uv) * frag_color;
    vec4 detail = texture(detail_tex, frag_uv * 8.0);
    float mask = texture(mask_tex, frag_uv).r;
    out_color = vec4(mix(base.rgb, base.rgb * detail.rgb, mask), base.a);
}
