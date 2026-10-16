// World-space normal as color, the scene view's Normals mode, and raw (0
// where nothing is drawn) for the engine's scene_ssr step, which tells the
// two apart by the draw's colour alpha: 1 encodes, 0 writes the normal as
// it is. Same inputs as world.frag (the shared world vertex stage). Alpha
// clipping cuts the same holes as the shaded draw, so the depth this pass
// writes matches the scene's.
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
};

void main() {
    if (texture(tex, frag_uv).a < draw_params.x) discard;
    vec3 n = normalize(frag_normal);
    out_color = frag_color.a > 0.5 ? vec4(n * 0.5 + 0.5, 1.0) : vec4(n, 1.0);
}
