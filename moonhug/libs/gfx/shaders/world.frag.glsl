// texture * vertex color. Untextured draws bind the 1x1 white texture.
// The texture is color data stored as sRGB, decoded to linear here (the
// vertex color arrives linear from world.vert).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal; // for a normals pass only
layout(location = 3) in vec3 frag_world_pos;
layout(location = 4) in vec4 frag_tangent; // a UI quad under a mask: its clip, see ui_clip
layout(location = 5) in vec2 frag_uv2;     // the same

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
    mat4 view_proj;
    vec4 probe_pos;  // the draw's reflection probe: xyz its centre, w = 1 when box projected
    vec4 probe_min;  // xyz the box, w = the probe's intensity
    vec4 probe_max;  // xyz the box, w = 1 when a probe is bound, 2 when its irradiance is bound too
    vec4 probe2_pos; // what the probe blends with (another probe or the environment): xyz its centre, w = 1 when box projected
    vec4 probe2_min; // xyz the box, w = its specular intensity
    vec4 probe2_max; // xyz the box, w = its diffuse intensity
    vec4 probe_blend; // x = the probe's weight, 1 = no blend
    uvec4 draw_layers; // x = the draw's render layers (gfx.draw_mesh layers), every bit for batch draws
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


// UI clip (the engine's UiMask): a quad under a mask carries the clip in
// three inputs a UI quad has no other use for, marked by frag_tangent.w of 2
// or more, a value no real tangent has (gfx.draw_quad `clip`). Returns how
// much of the pixel is inside, with an edge one pixel soft or as soft as the
// mask says, and 1 for a quad with no mask.
float ui_clip(vec4 t, vec3 n, vec2 outer) {
    if (t.w < 1.5) return 1.0;
    int mark = int(t.w + 0.5) - 2;
    // The nearest mask: t.xy is the pixel's place from the mask's centre in
    // the mask's own units, n.xy its half size, n.z its corner radius, t.z
    // the width its edge fades over. The mark's low four bits say which
    // corners are round: 1 top left, 2 top right, 4 bottom right, 8 bottom left.
    vec2 p = t.xy;
    int corner = p.x > 0.0 ? (p.y > 0.0 ? 2 : 4) : (p.y > 0.0 ? 1 : 8);
    float r = (mark & corner) != 0 ? min(n.z, min(n.x, n.y)) : 0.0;
    vec2 q = abs(p) - n.xy + r;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    float px = max(fwidth(d), 1e-6);
    float a = t.z > 0.0 ? clamp(-d / max(t.z, px), 0.0, 1.0) : clamp(0.5 - d / px, 0.0, 1.0);
    // The masks above it, as one rect: `outer` runs from -1 to 1 inside it.
    if ((mark & 16) != 0) {
        vec2 e = (1.0 - abs(outer)) / max(fwidth(outer), vec2(1e-6));
        a *= clamp(min(e.x, e.y) + 0.5, 0.0, 1.0);
    }
    return a;
}

vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void main() {
    vec4 t = texture(tex, frag_uv);
    out_color = vec4(srgb_to_linear(t.rgb), t.a) * frag_color;
    out_color.a *= ui_clip(frag_tangent, frag_normal, frag_uv2);
    if (out_color.a < draw_params.x) discard;
    // A normals pass (gfx.pass_output_normals): the normal as the colour.
    if (draw_params.y > 0.5) {
        out_color = vec4(normalize(frag_normal), 1.0);
        return;
    }
    out_color.rgb = mix(out_color.rgb, fog_color.rgb, fog_amount(frag_world_pos));
}
