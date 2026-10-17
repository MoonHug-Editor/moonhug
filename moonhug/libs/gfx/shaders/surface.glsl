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
//   s.normal    world-space, preset to vertex_normal(). For a normal map:
//               s.normal = perturb_normal(sample.xyz * 2.0 - 1.0)
//   s.emissive  added after lighting, preset to zero
//   s.refraction for a transparent material: the thickness of glass the view
//               bends through, world units, preset to the Lit material's
//               (0 = none)
//
// A fragment whose s.alpha ends below the material's alpha cutoff is
// discarded (Material alpha clipping, draw_params.x, 0 = off).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2,
// fragment uniform buffers in set 3. Your property block goes at
// set = 3, binding = 1, extra textures at set = 2, bindings 1..6.

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;
layout(location = 4) in vec4 frag_tangent; // world tangent, w bitangent sign; zero = none
layout(location = 5) in vec2 frag_uv2;     // the second texture coordinate set (a baked atlas); zero = none

layout(set = 2, binding = 0) uniform sampler2D tex;

#define MAX_LIGHTS 256
#define MAX_CASCADES 4
#define MAX_SHADOW_TILES 48
// The screen's grid of light tiles (gfx CLUSTER_COLS, CLUSTER_ROWS).
#define CLUSTER_COLS 16
#define CLUSTER_ROWS 9

struct GpuLight {
    vec4 pos_type;    // xyz = position, w = kind (0 dir, 1 point, 2 spot)
    vec4 dir_range;   // xyz = normalized travel direction, w = range
    vec4 color_outer; // rgb premultiplied by intensity, w = cos outer half-angle
    vec4 params;      // x = cos inner half-angle, y = first shadow tile, z = shadow tiles (0 none, 1 spot, 6 point), w reserved
};

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 ambient_count;  // x = ambient floor, y = light count
    vec4 cam_pos;        // xyz = camera world position
    // The first 8 lights, the prefix hand-written full shaders read. The
    // template reads every light from ClusterUBO.
    GpuLight first_lights[8];
    vec4 cluster_params; // x = 1 / target width, y = 1 / target height (pixels)
    // The directional light's cascades (gfx.set_shadow_cascades), tiles of
    // shadow_map: view_proj, the tile in atlas uv, x one texel's world size,
    // y the depth bias in the cascade's depth units.
    mat4 cascade_vp[MAX_CASCADES];
    vec4 cascade_rects[MAX_CASCADES];
    vec4 cascade_params[MAX_CASCADES];
    vec4 shadow_params; // x = one atlas texel in uv, y = cascade count (0 none), z = where shadows end, w = the light they belong to
    vec4 env_params;    // x = diffuse intensity, y = specular intensity, z = the specular cube's last mip (gfx.set_environment)
    // Spot and point light shadows (gfx.set_shadow_atlas), tiles of
    // shadow_atlas: x one atlas texel in uv, y bias along the light ray
    // (world), z normal bias (texels) of these tiles, w the cascades'.
    vec4 atlas_params;
    mat4 tile_vp[MAX_SHADOW_TILES];
    vec4 tile_rects[MAX_SHADOW_TILES];
    vec4 tile_params[MAX_SHADOW_TILES]; // x near, y far, z one texel's world size at distance 1
};

// Per draw, from gfx.draw_mesh: x = the material's alpha cutoff (0 = no
// clipping), then the pass's fog (gfx.Fog: colour and mode, density, start,
// end, height, height falloff, the sky's share) and the camera (view_pos), for the
// fog's distance.
// draw_params: x = the material's alpha cutoff (0 = off), y = 1 on a pass
// that wants the surface's world-space normal as the colour instead of its
// shading (gfx.pass_output_normals, the engine's scene_ssr step).
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
};

// Every light of the pass (gfx.set_lights), and for each tile of the screen's
// CLUSTER_COLS x CLUSTER_ROWS grid a bit per light that reaches into it: a
// point or spot light's range sphere covers the tile, a directional light
// covers every tile. Two uvec4 per tile hold its 256 bits, light i at word
// i / 32, bit i % 32.
layout(set = 3, binding = 3) uniform ClusterUBO {
    GpuLight lights[MAX_LIGHTS];
    uvec4 tile_bits[CLUSTER_COLS * CLUSTER_ROWS * 2];
};

// The light tile the fragment is in.
int light_tile() {
    ivec2 t = ivec2(gl_FragCoord.xy * cluster_params.xy * vec2(CLUSTER_COLS, CLUSTER_ROWS));
    t = clamp(t, ivec2(0), ivec2(CLUSTER_COLS - 1, CLUSTER_ROWS - 1));
    return t.y * CLUSTER_COLS + t.x;
}

// Word `w` of tile `tile`'s light bits.
uint light_tile_word(int tile, int w) {
    uvec4 v = tile_bits[tile * 2 + (w >> 2)];
    return v[w & 3];
}

// The shadow maps, bound by gfx at reserved slots for every shader that
// declares them, sampled with a depth comparison (1 lit, 0 shadowed, filtered
// between): the directional cascades' atlas and the spot and point lights'
// atlas. A 1x1 depth of 1 stands in when a pass has none. Material texture
// rows use bindings 1..6.
layout(set = 2, binding = 7) uniform sampler2DShadow shadow_map;
layout(set = 2, binding = 10) uniform sampler2DShadow shadow_atlas;

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

// The opaque image so far (the scene_copy step), what a refracting surface
// shows: black when no step copied it. `refracted(n, t, a)` reads it where the
// view ray lands after bending into the surface (Snell's law, glass's index
// of 1.5) and travelling `t` world units through it: straight on it barely
// moves, at a grazing edge it bends hard, and a solid ball of its own
// diameter inverts what is behind it, as glass does. refracted() (below the
// environment, which stands in beyond the copy's edge) does the lookup.
layout(set = 2, binding = 12) uniform sampler2D scene_color;


// The screen's ambient occlusion (the scene_ssao step): red is how much
// ambient light reaches the pixel, blue how much direct light, both 1 when
// there is none.
layout(set = 2, binding = 11) uniform sampler2D ambient_occlusion;

// x: the factor for the environment's light, y: for the lights'.
vec2 screen_occlusion() {
    return texture(ambient_occlusion, gl_FragCoord.xy * cluster_params.xy).rb;
}
// The screen's reflections (the scene_ssr step), premultiplied: rgb what the
// pixel's mirror ray sees times the confidence, alpha the confidence, 0
// where there are none. Its mip levels blur the image for a rough surface.
layout(set = 2, binding = 13) uniform sampler2D screen_reflections;

// What stands in for the environment's reflection at this pixel: the
// screen's reflection read blurrier the rougher the surface, and faded out
// toward rough surfaces, whose wide lobe one mirror ray does not stand for.
vec4 screen_reflection(float roughness) {
    vec4 r = textureLod(screen_reflections, gl_FragCoord.xy * cluster_params.xy, roughness * 5.0);
    return r * (1.0 - smoothstep(0.5, 0.8, roughness));
}
// The environment (gfx.set_environment): the specular cube prefiltered for
// rising roughness along its mips, and the diffuse irradiance cube. White
// when the pass has none, so the ambient level lights uniformly.
layout(set = 2, binding = 8) uniform samplerCube env_specular; // the draw's reflection probe's cube when one is bound (probe_max.w)
layout(set = 2, binding = 9) uniform samplerCube env_irradiance; // the draw's probe's when one is bound with it (probe_max.w 2)
// What the draw's probe blends with near its box's edge (probe_blend.x
// below 1): another probe's cubes, or the environment's.
layout(set = 2, binding = 14) uniform samplerCube env_specular2;
layout(set = 2, binding = 15) uniform samplerCube env_irradiance2;

// The direction to read a box-projected probe in: where the reflected ray
// from `p` leaves the probe's box, seen from the probe's centre, so a flat
// surface reflects the room at its place instead of at infinity.
vec3 box_projected(vec3 r, vec3 p, vec3 centre, vec3 box_min, vec3 box_max) {
    vec3 safe = mix(r, vec3(1e-5), lessThan(abs(r), vec3(1e-5)));
    vec3 t1 = (box_max - p) / safe;
    vec3 t2 = (box_min - p) / safe;
    vec3 far = max(t1, t2);
    float t = min(min(far.x, far.y), far.z);
    return p + r * t - centre;
}

// What the environment shows along the ray `r` from `p`, at mip `lod`: the
// draw's probe when one is bound, box projected when it says so, else the
// scene's environment, each at its intensity. Near the probe's box edge it
// fades into what it blends with by its weight.
vec3 env_along(vec3 r, vec3 p, float lod) {
    if (probe_max.w < 0.5) return textureLod(env_specular, r, lod).rgb * env_params.y;
    vec3 dir = probe_pos.w > 0.5 ? box_projected(r, p, probe_pos.xyz, probe_min.xyz, probe_max.xyz) : r;
    vec3 c = textureLod(env_specular, dir, lod).rgb * probe_min.w;
    if (probe_blend.x >= 1.0) return c;
    vec3 dir2 = probe2_pos.w > 0.5 ? box_projected(r, p, probe2_pos.xyz, probe2_min.xyz, probe2_max.xyz) : r;
    return mix(textureLod(env_specular2, dir2, lod).rgb * probe2_min.w, c, probe_blend.x);
}

// The environment's diffuse light on a surface facing `n`: the draw's
// probe's when it lights diffusely, else the scene's environment, faded
// into what the probe blends with near its box's edge.
vec3 env_irradiance_at(vec3 n) {
    vec3 c = texture(env_irradiance, n).rgb * (probe_max.w > 1.5 ? probe_min.w : env_params.x);
    if (probe_max.w < 0.5 || probe_blend.x >= 1.0) return c;
    return mix(texture(env_irradiance2, n).rgb * probe2_max.w, c, probe_blend.x);
}

// The environment's reflection for the surface at `p` with the reflected
// ray `r`, blurrier the rougher the surface.
vec3 env_reflection(vec3 r, vec3 p, float roughness) {
    return env_along(r, p, roughness * env_params.z);
}

// What a refracting surface shows (Material.refraction, surface_main):
// the opaque copy (scene_color) read where the view ray lands after
// bending into the surface and travelling `t` through it. Where that lands
// beyond the copy's edge a stand-in takes over, blended in over the last
// fiftieth of the screen before it: on a curved surface (the bend changes
// from pixel to pixel: a ball) the environment along the bent ray, which
// reads as sky and ground seen through glass (the draw's probe box projected
// from where the ray leaves the surface, as reflections read it, so a
// room's walls stand where they are), and on a flat face (one bend
// across it: a slab) what sits straight behind the pixel, since one
// environment colour over a whole face looks like paint. Without an
// environment every surface falls back to what is behind it. A curved
// surface reads the copy one mip blurrier, a rough one (`a`, roughness
// squared) blurrier still, a flat smooth face sharp.
vec3 refracted(vec3 n, float t, float a) {
    vec3 inside = refract(-normalize(view_pos.xyz - frag_world_pos), n, 1.0 / 1.5);
    vec4 here = view_proj * vec4(frag_world_pos, 1.0);
    vec4 there = view_proj * vec4(frag_world_pos + inside * t, 1.0);
    vec2 uv = gl_FragCoord.xy * cluster_params.xy;
    vec2 offset = (there.xy / there.w - here.xy / here.w) * vec2(0.5, -0.5);
    float curved = smoothstep(0.0, 0.002, length(fwidth(offset)));
    vec2 look = uv + offset;
    // Up to one mip level blurrier than the lens's minification asks where
    // the surface curves: a ball is never a perfect lens, and under TAA's
    // sub-pixel camera moves a sharp minified image flickers where fine
    // detail lands. Roughness spreads the light over more of the copy.
    float blur = curved + a * float(textureQueryLevels(scene_color));
    vec3 screen = texture(scene_color, clamp(look, vec2(0.001), vec2(0.999)), blur).rgb;
    float outside = max(max(-look.x, look.x - 1.0), max(-look.y, look.y - 1.0));
    float beyond = smoothstep(-0.02, 0.0, outside);
    if (beyond <= 0.0) return screen;
    vec3 behind = texture(scene_color, uv, blur).rgb;
    vec3 stand_in = behind;
    if (env_params.z > 0.0 || probe_max.w > 0.5) stand_in = mix(behind, env_along(inside, frag_world_pos + inside * t, 1.0), curved);
    return mix(screen, stand_in, beyond);
}

layout(location = 0) out vec4 out_color;

struct Surface {
    vec3  albedo;
    float alpha;
    vec3  normal;
    vec3  emissive;
    float metallic;
    float smoothness;
    float occlusion;
    float refraction; // 0 none: how far the scene behind bends through the surface (transparent materials)
};

// The built-in Lit's own material (engine Material.lit), declared only when
// lit.frag.glsl compiles this template: a user surface shader owns binding 1
// and samplers 1..6 for its own properties and textures.
#ifdef MOONHUG_LIT_MATERIAL
layout(set = 3, binding = 1) uniform LitMaterial {
    vec4 lit_params;   // x metallic, y smoothness, z normal scale (0 = no map), w occlusion strength
    vec4 lit_emission; // rgb emission color, linear (times the emission map), w refraction
    vec4 lit_uv;       // xy the maps' uv scale, zw their offset (KHR_texture_transform)
    vec4 lit_flags;    // x = 1 reads the maps clamped to their edges, y = the maps read from the second uv set, as bits (1 base, 2 metallic roughness, 4 normal, 8 occlusion, 16 emission)
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

// The interpolated vertex normal, reversed on a back face (a material that
// draws both faces): the back of a thin sheet is lit as a surface of its
// own, facing the other way.
vec3 vertex_normal() {
    vec3 n = normalize(frag_normal);
    return gl_FrontFacing ? n : -n;
}

// A tangent-space normal (a normal map's texel unpacked to -1..1, z out of
// the surface) to world space. Uses the vertex tangent, or, where there is
// none (quads without uvs, lines), a frame from the position and uv
// derivatives. `strength` scales the map's tilt: 0 is vertex_normal(). On a
// back face the result is reversed whole, as vertex_normal() is: a bump on
// the front is a dent on the back.
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
    vec3 r = normalize(mat3(t, b, n) * tn);
    return gl_FrontFacing ? r : -r;
}

vec3 perturb_normal(vec3 tangent_normal) {
    return perturb_normal(tangent_normal, 1.0);
}

// Toksvig: a normal map's smaller mip levels average its normals, so a
// texel's unpacked normal is shorter where the bumps under it point different
// ways. That spread, (1 - len) / len, becomes roughness, so the highlight
// widens as the bumps it would scatter into blur away instead of sparkling.
// `len` is the filtered normal's length relative to the full-size texel's,
// and the first hundredth is 8-bit rounding, not spread.
float toksvig_smoothness(float smoothness, float len) {
    len = clamp(len, 1e-3, 1.0);
    float spread = max(1.0 - len - 0.01, 0.0) / len;
    float a = (1.0 - smoothness) * (1.0 - smoothness);
    return 1.0 - sqrt(sqrt(clamp(a * a + spread, 0.0, 1.0)));
}

// Geometric specular anti-aliasing (Kaplanyan et al. 2016, as Filament and
// HDRP do): where the normal turns faster across the screen than one pixel can
// show, the perceptual roughness rises, so a highlight spreads over the pixels
// instead of flickering between them. Reads screen derivatives: call it where
// every pixel of a 2x2 block still runs (before a discard).
float specular_aa(float perceptual_roughness, vec3 n) {
    vec3 du = dFdx(n);
    vec3 dv = dFdy(n);
    float variance = 0.15 * (dot(du, du) + dot(dv, dv));
    float kernel = min(2.0 * variance, 0.2);
    float a = perceptual_roughness * perceptual_roughness;
    return sqrt(sqrt(clamp(a * a + kernel, 0.0, 1.0)));
}

// Direction toward the camera from the fragment, for rim and specular terms.
vec3 view_dir() {
    return normalize(cam_pos.xyz - frag_world_pos);
}

// 3x3 comparison taps (each a filtered 2x2 compare) around `uv`, a point of
// one atlas tile `rect` (atlas uv x, y, w, h), clamped 1.5 texels inside the
// tile so no tap reads a neighbouring tile. 1 lit, 0 shadowed.
float shadow_pcf(sampler2DShadow map, vec4 rect, vec2 uv, float depth, float texel) {
    vec2 lo = rect.xy + vec2(texel * 1.5);
    vec2 hi = rect.xy + rect.zw - vec2(texel * 1.5);
    vec2 c = rect.xy + uv * rect.zw;
    float lit = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            lit += texture(map, vec3(clamp(c + vec2(x, y) * texel, lo, hi), depth));
        }
    }
    return lit / 9.0;
}

// The directional light's shadow at a surface point with geometric normal
// `n`: the first cascade whose tile holds the point, looked up a few of that
// cascade's texels along the normal (against acne), faded out over the last
// tenth of the shadow distance. 1 past the distance or with no cascades.
float cascade_shadow(vec3 world_pos, vec3 n) {
    int count = int(shadow_params.y + 0.5);
    if (count == 0) return 1.0;
    float end = shadow_params.z;
    float dist = length(world_pos - cam_pos.xyz);
    if (dist >= end) return 1.0;
    float fade = smoothstep(end * 0.9, end, dist);
    for (int c = 0; c < count; ++c) {
        vec3 p = world_pos + n * (cascade_params[c].x * atlas_params.w);
        vec4 lp = cascade_vp[c] * vec4(p, 1.0);
        vec3 ndc = lp.xyz / lp.w;
        vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        float margin = 2.0 * shadow_params.x / cascade_rects[c].z; // two texels, in the tile's uv
        if (uv.x < margin || uv.x > 1.0 - margin || uv.y < margin || uv.y > 1.0 - margin || ndc.z < 0.0 || ndc.z > 1.0) continue;
        float lit = shadow_pcf(shadow_map, cascade_rects[c], uv, ndc.z - cascade_params[c].y, shadow_params.x);
        return mix(lit, 1.0, fade);
    }
    return 1.0;
}

// A spot or point light's shadow at a surface point with geometric normal
// `n`: its tile of the atlas (a point light's six, +X -X +Y -Y +Z -Z, by the
// direction's major axis), looked up a few texels along the normal, with
// the bias taken along the light ray in world units. 1 for a light without.
float punctual_shadow(GpuLight l, vec3 world_pos, vec3 n) {
    int count = int(l.params.z + 0.5);
    if (count == 0) return 1.0;
    int tile = int(l.params.y + 0.5);
    vec3 d = world_pos - l.pos_type.xyz;
    if (count == 6) {
        vec3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) tile += d.x > 0.0 ? 0 : 1;
        else if (a.y >= a.z) tile += d.y > 0.0 ? 2 : 3;
        else tile += d.z > 0.0 ? 4 : 5;
    }
    vec4 tp = tile_params[tile];
    vec3 p = world_pos + n * (tp.z * length(d) * atlas_params.z);
    vec4 lp = tile_vp[tile] * vec4(p, 1.0);
    if (lp.w <= tp.x) return 1.0;
    vec3 ndc = lp.xyz / lp.w;
    vec2 uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0) return 1.0;
    // The view depth moved toward the light by the bias, back to the map's
    // depth (gfx.matrix4_perspective_z01: far / (far - near) * (1 - near / w)).
    float w = max(lp.w - atlas_params.y, tp.x);
    float depth = tp.y / (tp.y - tp.x) * (1.0 - tp.x / w);
    return shadow_pcf(shadow_atlas, tile_rects[tile], uv, depth, atlas_params.x);
}
