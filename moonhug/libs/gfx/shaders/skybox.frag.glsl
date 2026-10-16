// The environment behind the view: each pixel's view ray looks the source
// cube up (draw_sky: only where nothing nearer was drawn), under the fog's
// share for the sky: full at the horizon, gone straight up.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform samplerCube env;

layout(set = 3, binding = 1) uniform Params {
    mat4 inv_view_proj;
    vec4 fog_color;  // rgb, w = mode (0 off)
    vec4 fog_params; // unused here
    vec4 fog_more;   // y = the sky's share
};

void main() {
    vec2 ndc = vec2(frag_uv.x * 2.0 - 1.0, 1.0 - frag_uv.y * 2.0);
    vec4 near = inv_view_proj * vec4(ndc, 0.0, 1.0);
    vec4 far = inv_view_proj * vec4(ndc, 1.0, 1.0);
    vec3 dir = normalize(far.xyz / far.w - near.xyz / near.w);
    vec3 c = textureLod(env, dir, 0.0).rgb;
    if (fog_color.w > 0.5) {
        float up = clamp(dir.y, 0.0, 1.0);
        c = mix(c, fog_color.rgb, fog_more.y * (1.0 - up) * (1.0 - up));
    }
    out_color = vec4(c, 1.0);
}
