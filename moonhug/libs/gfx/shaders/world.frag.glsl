// texture * vertex color. Untextured draws bind the 1x1 white texture.
// The texture is color data stored as sRGB, decoded to linear here (the
// vertex color arrives linear from world.vert).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(location = 0) out vec4 out_color;

// Per draw, from gfx.draw_mesh: x = the material's alpha cutoff (0 = no
// clipping, batch draws push 0), then the pass's fog and the camera
// (surface.glsl says what each holds).
layout(set = 3, binding = 2) uniform DrawUBO {
    vec4 draw_params;
    vec4 fog_color;
    vec4 fog_params;
    vec4 fog_more;
    vec4 view_pos;
};

// Fog (gfx.set_fog, the DrawUBO): how much of the fog colour covers a point.
// Height fog scales the density by exp(-falloff * (y - height)), integrated
// along the ray from the camera (the mean over the ray's heights).
float fog_amount(vec3 world_pos) {
    int mode = int(fog_color.w + 0.5);
    if (mode == 0) return 0.0;
    vec3 d = world_pos - view_pos.xyz;
    float dist = length(d);
    float h = 1.0;
    if (fog_more.x > 0.0) {
        float k = fog_more.x;
        float ky = k * d.y;
        h = exp(-k * (view_pos.y - fog_params.w)) * (abs(ky) > 1e-4 ? (1.0 - exp(-ky)) / ky : 1.0);
    }
    float f;
    if (mode == 1) f = 1.0 - exp(-fog_params.x * h * dist);
    else if (mode == 2) { float x = fog_params.x * h * dist; f = 1.0 - exp(-x * x); }
    else f = clamp((dist - fog_params.y) / max(fog_params.z - fog_params.y, 1e-4), 0.0, 1.0) * clamp(h, 0.0, 1.0);
    return clamp(f, 0.0, 1.0);
}


vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    vec4 t = texture(tex, frag_uv);
    out_color = vec4(srgb_to_linear(t.rgb), t.a) * frag_color;
    if (out_color.a < draw_params.x) discard;
    out_color.rgb = mix(out_color.rgb, fog_color.rgb, fog_amount(frag_world_pos));
}
