// The surface shader template, part 1: everything a surface() function can
// read. A surface shader is a .glsl asset that declares
//
//     void surface(inout Surface s) { ... }
//
// and no main(): the importer wraps it between this file and
// surface_main.glsl, which runs the lighting (plugins/engine/docs/Materials.md).
// The built-in lit shader is the same template with a default surface().
//
// Set `s` from the inputs below and your own properties:
//   s.albedo     base color, preset to texture(tex, frag_uv) * frag_color
//   s.alpha      preset to that texture's alpha
//   s.metallic   0 dielectric to 1 metal, preset to 0
//   s.smoothness 0 rough to 1 mirror-like, preset to 0.5
//   s.occlusion  ambient light that reaches the point, preset to 1
//   s.normal    world-space, preset to the interpolated vertex normal. For a
//               normal map: s.normal = perturb_normal(sample.xyz * 2.0 - 1.0)
//   s.emissive  added after lighting, preset to zero
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2,
// fragment uniform buffers in set 3. Your property block goes at
// set = 3, binding = 1, extra textures at set = 2, bindings 1..7.

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;
layout(location = 4) in vec4 frag_tangent; // world tangent, w bitangent sign; zero = none

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
    vec4 cam_pos;       // xyz = camera world position
    GpuLight lights[MAX_LIGHTS];
    mat4 shadow_vp;     // the caster pass's view_proj (gfx.set_shadow)
    vec4 shadow_params; // x = one texel in uv, y = depth bias, z = 1 when a map is bound, w = its light index
    vec4 env_params;    // x = diffuse intensity, y = specular intensity, z = the specular cube's last mip (gfx.set_environment)
};

// The shadow map, bound by gfx at this reserved slot for every shader that
// declares it (white, depth 1, when no caster pass ran: nothing in shadow).
// Material texture rows use bindings 1..6.
layout(set = 2, binding = 7) uniform sampler2D shadow_map;
// The environment (gfx.set_environment): the specular cube prefiltered for
// rising roughness along its mips, and the diffuse irradiance cube. White
// when the pass has none, so the ambient level lights uniformly.
layout(set = 2, binding = 8) uniform samplerCube env_specular;
layout(set = 2, binding = 9) uniform samplerCube env_irradiance;

layout(location = 0) out vec4 out_color;

struct Surface {
    vec3  albedo;
    float alpha;
    vec3  normal;
    vec3  emissive;
    float metallic;
    float smoothness;
    float occlusion;
};

// The built-in Lit's own material (engine Material.lit), declared only when
// lit.frag.glsl compiles this template: a user surface shader owns binding 1
// and samplers 1..6 for its own properties and textures.
#ifdef MOONHUG_LIT_MATERIAL
layout(set = 3, binding = 1) uniform LitMaterial {
    vec4 lit_params;   // x metallic, y smoothness, z normal scale (0 = no map), w occlusion strength
    vec4 lit_emission; // rgb emission color, linear (times the emission map)
};
layout(set = 2, binding = 1) uniform sampler2D metallic_roughness_map; // glTF packing: g roughness, b metallic
layout(set = 2, binding = 2) uniform sampler2D normal_map;
layout(set = 2, binding = 3) uniform sampler2D occlusion_map;          // r
layout(set = 2, binding = 4) uniform sampler2D emission_map;           // color, sRGB
#endif

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

// A color texture's sample (stored as sRGB) to linear light, the space the
// template lights in. Data textures (normal maps, masks) are not decoded.
vec3 srgb_to_linear(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

vec4 srgb_to_linear(vec4 c) {
    return vec4(srgb_to_linear(c.rgb), c.a);
}

// A tangent-space normal (a normal map's texel unpacked to -1..1, z out of
// the surface) to world space. Uses the vertex tangent, or, where there is
// none (quads without uvs, lines), a frame from the position and uv
// derivatives. `strength` scales the map's tilt: 0 is the vertex normal.
vec3 perturb_normal(vec3 tangent_normal, float strength) {
    vec3 n = normalize(frag_normal);
    vec3 tn = vec3(tangent_normal.xy * strength, tangent_normal.z);
    vec3 t, b;
    if (dot(frag_tangent.xyz, frag_tangent.xyz) > 1e-8) {
        t = normalize(frag_tangent.xyz - n * dot(n, frag_tangent.xyz));
        b = cross(n, t) * (frag_tangent.w < 0.0 ? -1.0 : 1.0);
    } else {
        vec3 dp1 = dFdx(frag_world_pos);
        vec3 dp2 = dFdy(frag_world_pos);
        vec2 duv1 = dFdx(frag_uv);
        vec2 duv2 = dFdy(frag_uv);
        vec3 dp2perp = cross(dp2, n);
        vec3 dp1perp = cross(n, dp1);
        t = dp2perp * duv1.x + dp1perp * duv2.x;
        b = dp2perp * duv1.y + dp1perp * duv2.y;
        float invmax = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-12));
        t *= invmax;
        b *= invmax;
    }
    return normalize(mat3(t, b, n) * tn);
}

vec3 perturb_normal(vec3 tangent_normal) {
    return perturb_normal(tangent_normal, 1.0);
}

// Direction toward the camera from the fragment, for rim and specular terms.
vec3 view_dir() {
    return normalize(cam_pos.xyz - frag_world_pos);
}

// How lit the fragment is by the shadow-casting light, 0 (shadowed) to 1:
// a 3x3 PCF of the shadow map around the fragment's light-space position.
// Outside the map, or with no map bound, the fragment counts as lit, which
// is the clamp-to-edge border SDL_GPU samplers lack.
float shadow_factor(vec3 world_pos) {
    if (shadow_params.z < 0.5) return 1.0;
    vec4 lp = shadow_vp * vec4(world_pos, 1.0);
    vec3 ndc = lp.xyz / lp.w;
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 1.0 - (ndc.y * 0.5 + 0.5));
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0) return 1.0;
    float depth = ndc.z - shadow_params.y;
    float texel = shadow_params.x;
    float lit = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float d = texture(shadow_map, uv + vec2(x, y) * texel).r;
            lit += depth <= d ? 1.0 : 0.0;
        }
    }
    return lit / 9.0;
}
