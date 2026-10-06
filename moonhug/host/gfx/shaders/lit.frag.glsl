// Built-in "lit" shader: texture * color with a lambert term per light.
// Light parameters come from the per-pass Light UBO (gfx.set_lights — the
// engine feeds it from the scene's Light components, or defaults to one white
// directional).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2,
// fragment uniform buffers in set 3.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

#define MAX_LIGHTS 8

struct GpuLight {
    vec4 pos_type;    // xyz = position, w = kind (0 dir, 1 point, 2 spot)
    vec4 dir_range;   // xyz = normalized travel direction, w = range
    vec4 color_outer; // rgb premultiplied by intensity, w = cos outer half-angle
    vec4 params;      // x = cos inner half-angle, yzw reserved
};

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 ambient_count; // x = ambient floor, y = light count
    vec4 cam_pos;       // xyz = camera world position (unused here; specular shaders read it)
    GpuLight lights[MAX_LIGHTS];
};

layout(location = 0) out vec4 out_color;

// Smooth, artist-predictable falloff: 1 at the light, 0 at range, no hot
// inverse-square center. (1 - (d/range)^2)^2, clamped.
float light_attenuation(GpuLight l, vec3 to_frag, float dist) {
    if (l.pos_type.w < 0.5) return 1.0; // directional
    float range = max(l.dir_range.w, 1e-4);
    float ratio = dist / range;
    float a = clamp(1.0 - ratio * ratio, 0.0, 1.0);
    a *= a;
    if (l.pos_type.w > 1.5) { // spot: fade between inner and outer cone
        float cos_a = dot(to_frag, l.dir_range.xyz);
        float inner = l.params.x;
        float outer = l.color_outer.w;
        a *= clamp((cos_a - outer) / max(inner - outer, 1e-4), 0.0, 1.0);
    }
    return a;
}

void main() {
    vec3 n = normalize(frag_normal);
    float ambient = ambient_count.x;
    int count = int(ambient_count.y);

    vec3 light = vec3(ambient);
    for (int i = 0; i < count; ++i) {
        GpuLight l = lights[i];
        vec3 L; // direction the light travels at this fragment
        float dist = 0.0;
        if (l.pos_type.w < 0.5) {
            L = l.dir_range.xyz;
        } else {
            vec3 d = frag_world_pos - l.pos_type.xyz;
            dist = length(d);
            L = d / max(dist, 1e-6);
        }
        float diffuse = max(dot(n, -L), 0.0);
        float atten = light_attenuation(l, L, dist);
        light += l.color_outer.rgb * ((1.0 - ambient) * diffuse * atten);
    }

    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb * light, base.a);
}
