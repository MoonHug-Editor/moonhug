// World-space normal as color, the scene view's Normals mode. Same inputs
// as world.frag (the shared world vertex stage). Alpha clipping cuts the
// same holes as the shaded draw.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

// Per draw, from gfx.draw_mesh: x = the material's alpha cutoff (0 = no
// clipping). The rest is the pass's fog and camera, unused here.
layout(set = 3, binding = 2) uniform DrawUBO {
    vec4 draw_params;
    vec4 fog_color;
    vec4 fog_params;
    vec4 fog_more;
    vec4 view_pos;
    mat4 view_proj;
    vec4 probe_pos;  // the draw's reflection probe: xyz its centre, w = 1 when box projected
    vec4 probe_min;  // xyz the box, w = the probe's intensity
    vec4 probe_max;  // xyz the box, w = 1 when a probe is bound
};

void main() {
    if (texture(tex, frag_uv).a < draw_params.x) discard;
    vec3 n = normalize(frag_normal);
    out_color = vec4(n * 0.5 + 0.5, 1.0);
}
