// MINIMAL user shader example: visualizes world-space normals (RGB = XYZ).
// Assign to a Material's `custom_shader` — the effect is immediate, no
// properties needed. For the material property block example, see
// stripes.glsl.
//
// User shaders are FRAGMENT stage only — the engine's world vertex shader
// feeds them. Conventions (declare the sampler even if unused):
//   inputs:     frag_uv (loc 0), frag_color (loc 1), frag_normal (loc 2)
//   sampler:    set = 2, binding = 0
//   light:      optional LightUBO at set = 3, binding = 0 (see lit.frag.glsl)
//   properties: optional block at set = 3, binding = 1 (see stripes.glsl)
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal) * 0.5 + 0.5;
    vec4 tex_px = texture(tex, frag_uv);
    out_color = vec4(pow(tex_px.rgb, vec3(2.2)), tex_px.a) * frag_color * vec4(n, 1.0);
}
