// The surface shader template, part 2: the lighting. Presets the Surface,
// lets surface() change it, then lights it: metal/roughness physically
// based shading per light that reaches the fragment's screen tile (GGX distribution,
// height-correlated Smith visibility, Schlick Fresnel), plus the
// environment for what no light reaches: its irradiance for diffuse, its
// prefiltered reflection times the split-sum fit for specular. Diffuse is
// not divided by pi, so a light of intensity 1 lights white albedo to 1, as
// Lambert did.

const float PI = 3.14159265359;

float D_GGX(float NoH, float a) {
    float a2 = a * a;
    float f = (NoH * a2 - NoH) * NoH + 1.0;
    return a2 / (PI * f * f);
}

float V_SmithGGXCorrelated(float NoV, float NoL, float a) {
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1e-5);
}

vec3 F_Schlick(float VoH, vec3 f0) {
    return f0 + (1.0 - f0) * pow(1.0 - VoH, 5.0);
}

// The split-sum environment BRDF's analytic fit (Karis): how much of a
// uniform environment a surface reflects, for the ambient specular.
vec3 env_brdf_approx(vec3 f0, float roughness, float NoV) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = roughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    return f0 * ab.x + ab.y;
}

// The Surface before surface() changes it: the texture times the color, and
// the built-in Lit's maps when this is the Lit shader.
Surface surface_preset() {
    vec4 base = srgb_to_linear(texture(tex, frag_uv)) * frag_color;
    Surface s;
    s.albedo     = base.rgb;
    s.alpha      = base.a;
    s.normal     = vertex_normal();
    s.emissive   = vec3(0.0);
    s.metallic   = 0.0;
    s.smoothness = 0.5;
    s.occlusion  = 1.0;
    s.refraction = 0.0;
#ifdef MOONHUG_LIT_MATERIAL
    s.refraction = lit_emission.w;
    vec4 mr = texture(metallic_roughness_map, frag_uv);
    s.metallic   = lit_params.x * mr.b;
    s.smoothness = 1.0 - (1.0 - lit_params.y) * mr.g;
    if (lit_params.z > 0.0) {
        vec3 tn = texture(normal_map, frag_uv).xyz * 2.0 - 1.0;
        s.normal = perturb_normal(tn, lit_params.z);
        // Against the same texel at full size: a map stored a little short
        // (compression, authoring) is not a spread of directions.
        float full = length(textureLod(normal_map, frag_uv, 0.0).xyz * 2.0 - 1.0);
        s.smoothness = toksvig_smoothness(s.smoothness, length(tn) / max(full, 1e-3));
    }
    s.occlusion  = mix(1.0, texture(occlusion_map, frag_uv).r, lit_params.w);
    s.emissive   = lit_emission.rgb * srgb_to_linear(texture(emission_map, frag_uv).rgb);
#endif
    return s;
}

#ifdef MOONHUG_CASTER
// The caster variant, for depth passes of alpha-clipped materials (shadow
// casters, the depth prepass): the same surface(), no lighting, no color, so
// a pixel clipping cuts away casts no shadow and hides nothing.
void main() {
    Surface s = surface_preset();
    surface(s);
    if (s.alpha < draw_params.x) discard;
}
#else
void main() {
    Surface s = surface_preset();
    surface(s);
    vec3 n = normalize(s.normal);
    // Perceptual, floored so GGX stays finite, and widened where the normal
    // turns faster than a pixel (before the discard: it reads derivatives).
    float roughness = specular_aa(clamp(1.0 - s.smoothness, 0.045, 1.0), n);
    if (s.alpha < draw_params.x) discard;
    // A normals pass: the normal as it is (its map applied), nothing else.
    if (draw_params.y > 0.5) {
        out_color = vec4(n, 1.0);
        return;
    }

    vec3 v = view_dir();
    float NoV = max(dot(n, v), 1e-4);
    float metallic = clamp(s.metallic, 0.0, 1.0);
    float a = roughness * roughness;
    vec3 f0 = mix(vec3(0.04), s.albedo, metallic);
    vec3 diffuse_color = s.albedo * (1.0 - metallic);

    // The lights that reach this fragment's screen tile: its bits, lowest
    // first, one word of 32 lights at a time.
    vec3 color = vec3(0.0);
    int count = int(ambient_count.y + 0.5);
    int tile = light_tile();
    vec3 geometric_n = vertex_normal();
    for (int w = 0; w < (count + 31) / 32; ++w) {
        uint bits = light_tile_word(tile, w);
        while (bits != 0u) {
            int i = w * 32 + findLSB(bits);
            bits &= bits - 1u;
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
            vec3 to_light = -L;
            float NoL = max(dot(n, to_light), 0.0);
            if (NoL <= 0.0) continue;
            float atten = light_attenuation(l, L, dist);
            if (atten <= 0.0) continue;
            if (l.pos_type.w < 0.5) {
                if (i == int(shadow_params.w + 0.5)) atten *= cascade_shadow(frag_world_pos, geometric_n);
            } else {
                atten *= punctual_shadow(l, frag_world_pos, geometric_n);
            }
            vec3 h = normalize(v + to_light);
            float NoH = max(dot(n, h), 0.0);
            float VoH = max(dot(v, h), 0.0);
            vec3 F = F_Schlick(VoH, f0);
            // Times pi: the diffuse term is not divided by it, so neither is
            // this. At most a hundred times a white diffuse surface: a peak
            // brighter than that only makes fireflies.
            vec3 spec = min(D_GGX(NoH, a) * V_SmithGGXCorrelated(NoV, NoL, a) * F * PI, vec3(100.0));
            vec3 kd = (1.0 - F) * diffuse_color;
            color += (kd + spec) * l.color_outer.rgb * (NoL * atten);
        }
    }

    // The screen's ambient occlusion shades the environment's light and a
    // part of the lights' (scene_ssao's `direct`).
    vec2 screen_ao = screen_occlusion();
    color *= screen_ao.y;

    // What no light reaches: the environment, shaded by occlusion.
    vec3 r = reflect(-v, n);
    vec3 irradiance = texture(env_irradiance, n).rgb * env_params.x;
    vec3 reflected = textureLod(env_specular, r, roughness * env_params.z).rgb * env_params.y;
    // The screen's reflection where the scene_ssr step found one.
    vec4 screen = screen_reflection(roughness);
    reflected = reflected * (1.0 - screen.a) + screen.rgb;
    color += (diffuse_color * irradiance + reflected * env_brdf_approx(f0, roughness, NoV)) * min(s.occlusion, screen_ao.x);

    // Capped well inside half-float range (65504): an overflow is infinite and
    // spreads through bloom as a white block.
    color = min(color + s.emissive, vec3(4096.0));
    float alpha = s.alpha;
    // A refracting surface shows the scene behind it, bent, tinted by its
    // albedo, under its own lighting by its alpha, and covers its pixel.
    if (s.refraction > 0.0) {
        color = mix(refracted(n, s.refraction) * s.albedo, color, alpha);
        alpha = 1.0;
    }
    color = mix(color, fog_color.rgb, fog_amount(frag_world_pos));
    out_color = vec4(color, alpha);
}
#endif
