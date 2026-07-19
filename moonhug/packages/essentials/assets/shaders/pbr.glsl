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
//        env_tex          EQUIRECT environment for reflections (IBL) — try
//                         assets/textures/studio_env.png; set env_tex_amount
//                         to 1 after assigning
//   4. Tweak the auto-filled properties:
//        emissive_color   rgb tint for the emissive map, w = strength (0 = off)
//        metallic         factor over the map (0 falls back to 1)
//        roughness        factor over the map (0 falls back to 1)
//        normal_strength  0 = normal map OFF (leave 0 unless normal_tex is
//                         assigned — the white fallback texture is not a
//                         valid normal map), 1 = full
//        env_strength     reflection amount (0 falls back to 1; metals are
//                         mostly THIS — without it chrome renders flat grey;
//                         >1 brightens, the env texture is LDR)
//        env_tex_amount   0 = built-in gradient environment, 1 = env_tex
//                         (leave 0 unless env_tex is assigned — the white
//                         fallback texture is not a valid environment)
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
layout(set = 2, binding = 5) uniform sampler2D env_tex; // equirect environment

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
    float env_strength;     // env reflection amount; 0 falls back to 1
    float env_tex_amount;   // 0 = gradient env, 1 = env_tex (equirect)
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

    // Environment reflections: a sky/ground gradient by default, the
    // equirect env_tex when env_tex_amount is up. Metals (and glossy glass)
    // are almost entirely this term. The env texture has no mips, so
    // roughness "blur" is faked by fading toward the gradient.
    float env_f = env_strength <= 0.0 ? 1.0 : env_strength;
    vec3 r = reflect(-v, n);
    vec3 sky = vec3(0.62, 0.68, 0.78);
    vec3 ground = vec3(0.22, 0.20, 0.18);
    vec3 env = mix(ground, sky, clamp(r.y * 0.5 + 0.5, 0.0, 1.0));
    float tex_amt = clamp(env_tex_amount, 0.0, 1.0);
    if (tex_amt > 0.0) {
        vec2 euv = vec2(atan(r.z, r.x) / (2.0 * PI) + 0.5,
                        acos(clamp(r.y, -1.0, 1.0)) / PI);
        vec3 env_px = pow(texture(env_tex, euv).rgb, vec3(2.2));
        env = mix(env, env_px, tex_amt * (1.0 - rough * 0.85));
    }
    vec3 f_amb = f0 + (max(vec3(1.0 - rough), f0) - f0) * pow(1.0 - nov, 5.0);
    vec3 env_spec = env * f_amb * (1.0 - rough * rough) * ao * env_f;

    // Diffuse ambient cedes energy to the reflection (1 - f_amb): smooth
    // glass at glancing angles is mirror, not milk.
    vec3 ambient = albedo * (1.0 - metal) * (1.0 - f_amb) * light_dir_ambient.w * ao;

    vec3 emissive = pow(texture(emissive_tex, frag_uv).rgb, vec3(2.2))
                  * emissive_color.rgb * emissive_color.w;

    vec3 rgb = pow(lo + ambient + env_spec + emissive, vec3(1.0 / 2.2)); // linear -> sRGB
    out_color = vec4(rgb, base_px.a);
}
