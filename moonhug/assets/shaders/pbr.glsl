// PBR EXAMPLE — glTF-style metallic-roughness shading (Cook-Torrance GGX)
// under the scene's directional Light. This is the multi-texture showcase:
// bindings 1..4 become named texture rows on the Material, assign a glTF
// model's maps to them (Damaged Helmet works out of the box).
//
// How to use:
//   1. Create a Material, set `custom_shader` to this file.
//   2. `texture` = the model's albedo/baseColor map.
//   3. Assign the auto-filled texture rows:
//        metal_rough_tex  glTF metallicRoughness (g=roughness, b=metallic)
//        normal_tex       tangent-space normal map
//        ao_tex           ambient occlusion (r channel)
//        emissive_tex     emissive map
//   4. Tweak the auto-filled properties:
//        emissive_color   rgb tint for the emissive map, w = strength (0 = off)
//        metallic         factor over the map (0 falls back to 1)
//        roughness        factor over the map (0 falls back to 1)
//        normal_strength  0 = normal map OFF (leave 0 unless normal_tex is
//                         assigned — the white fallback texture is not a
//                         valid normal map), 1 = full
//        env_strength     fake-environment reflection amount (0 falls back
//                         to 1; metals are mostly THIS — without it chrome
//                         renders flat grey)
//
// Unassigned texture rows bind WHITE: metal_rough/ao neutral, emissive
// gated by emissive_color.w, normals gated by normal_strength.
//
// Tangents: the mesh has none, so the tangent frame is derived per-pixel
// from position/uv derivatives (Schüler's cotangent frame) — good enough
// until imported tangents land. Albedo/emissive are treated as sRGB and the
// result is re-encoded (the rest of the engine is gamma-naive; doing it
// in-shader keeps PBR plausible without a linear pipeline).
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;             // albedo
layout(set = 2, binding = 1) uniform sampler2D metal_rough_tex; // g=rough, b=metal
layout(set = 2, binding = 2) uniform sampler2D normal_tex;
layout(set = 2, binding = 3) uniform sampler2D ao_tex;
layout(set = 2, binding = 4) uniform sampler2D emissive_tex;

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 light_dir_ambient; // xyz = direction light travels, w = ambient floor
    vec4 light_color;       // rgb premultiplied by intensity
    vec4 cam_pos;           // xyz = camera world position
};

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  emissive_color;   // rgb tint, w strength (0 = emissive off)
    float metallic;         // factor over the map; 0 falls back to 1
    float roughness;        // factor over the map; 0 falls back to 1
    float normal_strength;  // 0 = normal map off
    float env_strength;     // fake env reflections; 0 falls back to 1
};

layout(location = 0) out vec4 out_color;

const float PI = 3.14159265359;

// Per-pixel tangent frame from screen-space derivatives (no mesh tangents).
mat3 cotangent_frame(vec3 N, vec3 p, vec2 uv) {
    vec3 dp1 = dFdx(p);
    vec3 dp2 = dFdy(p);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);
    vec3 dp2perp = cross(dp2, N);
    vec3 dp1perp = cross(N, dp1);
    vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;
    float invmax = inversesqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
    return mat3(T * invmax, B * invmax, N);
}

void main() {
    vec4 base_px = texture(tex, frag_uv) * frag_color;
    vec3 albedo = pow(base_px.rgb, vec3(2.2)); // sRGB -> linear

    float metal_f = metallic  <= 0.0 ? 1.0 : metallic;
    float rough_f = roughness <= 0.0 ? 1.0 : roughness;
    vec4 mr = texture(metal_rough_tex, frag_uv);
    float rough = clamp(mr.g * rough_f, 0.04, 1.0); // floor keeps GGX finite
    float metal = clamp(mr.b * metal_f, 0.0, 1.0);

    vec3 n = normalize(frag_normal);
    if (normal_strength > 0.0) {
        vec3 nm = texture(normal_tex, frag_uv).xyz * 2.0 - 1.0;
        nm.xy *= normal_strength;
        n = normalize(cotangent_frame(n, frag_world_pos, frag_uv) * nm);
    }

    vec3 v = normalize(cam_pos.xyz - frag_world_pos);
    vec3 l = -light_dir_ambient.xyz;
    vec3 h = normalize(v + l);
    float nol = max(dot(n, l), 0.0);
    float nov = max(dot(n, v), 1e-4);
    float noh = max(dot(n, h), 0.0);

    // Cook-Torrance: GGX distribution, Smith-Schlick geometry, Schlick fresnel.
    float a = rough * rough;
    float a2 = a * a;
    float denom = noh * noh * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * denom * denom);
    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    float G = (nol / (nol * (1.0 - k) + k)) * (nov / (nov * (1.0 - k) + k));
    vec3 f0 = mix(vec3(0.04), albedo, metal);
    vec3 F = f0 + (1.0 - f0) * pow(1.0 - max(dot(h, v), 0.0), 5.0);

    vec3 spec = (D * G * F) / max(4.0 * nol * nov, 1e-4);
    // Diffuse keeps parity with the lit shader (no 1/π); the specular lobe
    // stays physical — an extra ×π there blows out highlights.
    vec3 diffuse = (1.0 - F) * (1.0 - metal) * albedo;
    vec3 lo = (diffuse + spec) * light_color.rgb * nol;

    float ao = texture(ao_tex, frag_uv).r;
    vec3 ambient = albedo * (1.0 - metal) * light_dir_ambient.w * ao;

    // Fake environment: a sky/ground hemisphere gradient sampled along the
    // reflection vector, fresnel-weighted and dulled by roughness. Metals are
    // almost entirely this term — real IBL replaces it someday.
    float env_f = env_strength <= 0.0 ? 1.0 : env_strength;
    vec3 r = reflect(-v, n);
    vec3 sky = vec3(0.62, 0.68, 0.78);
    vec3 ground = vec3(0.22, 0.20, 0.18);
    vec3 env = mix(ground, sky, clamp(r.y * 0.5 + 0.5, 0.0, 1.0));
    vec3 f_amb = f0 + (max(vec3(1.0 - rough), f0) - f0) * pow(1.0 - nov, 5.0);
    vec3 env_spec = env * f_amb * (1.0 - rough * rough) * ao * env_f;

    vec3 emissive = pow(texture(emissive_tex, frag_uv).rgb, vec3(2.2))
                  * emissive_color.rgb * emissive_color.w;

    vec3 rgb = pow(lo + ambient + env_spec + emissive, vec3(1.0 / 2.2)); // linear -> sRGB
    out_color = vec4(rgb, base_px.a);
}
