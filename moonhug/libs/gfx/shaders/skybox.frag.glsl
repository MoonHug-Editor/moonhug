// The environment behind the view: each pixel's view ray looks the source
// cube up (draw_sky: only where nothing nearer was drawn).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform samplerCube env;

layout(set = 3, binding = 1) uniform Params {
    mat4 inv_view_proj;
};

void main() {
    vec2 ndc = vec2(frag_uv.x * 2.0 - 1.0, 1.0 - frag_uv.y * 2.0);
    vec4 near = inv_view_proj * vec4(ndc, 0.0, 1.0);
    vec4 far = inv_view_proj * vec4(ndc, 1.0, 1.0);
    vec3 dir = normalize(far.xyz / far.w - near.xyz / near.w);
    out_color = vec4(textureLod(env, dir, 0.0).rgb, 1.0);
}
