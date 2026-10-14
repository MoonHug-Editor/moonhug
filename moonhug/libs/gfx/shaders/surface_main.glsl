// The surface shader template, part 2: the lighting. Presets the Surface,
// lets surface() change it, then lights it: metal/roughness physically
// based shading per light from the pass's Light UBO (GGX distribution,
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

void main() {
    vec4 base = srgb_to_linear(texture(tex, frag_uv)) * frag_color;
    Surface s;
    s.albedo     = base.rgb;
    s.alpha      = base.a;
    s.normal     = normalize(frag_normal);
    s.emissive   = vec3(0.0);
    s.metallic   = 0.0;
    s.smoothness = 0.5;
    s.occlusion  = 1.0;
#ifdef MOONHUG_LIT_MATERIAL
    vec4 mr = texture(metallic_roughness_map, frag_uv);
    s.metallic   = lit_params.x * mr.b;
    s.smoothness = 1.0 - (1.0 - lit_params.y) * mr.g;
    if (lit_params.z > 0.0) s.normal = perturb_normal(texture(normal_map, frag_uv).xyz * 2.0 - 1.0, lit_params.z);
    s.occlusion  = mix(1.0, texture(occlusion_map, frag_uv).r, lit_params.w);
    s.emissive   = lit_emission.rgb * srgb_to_linear(texture(emission_map, frag_uv).rgb);
#endif
    surface(s);

    vec3 n = normalize(s.normal);
    vec3 v = view_dir();
    float NoV = max(dot(n, v), 1e-4);
    float metallic = clamp(s.metallic, 0.0, 1.0);
    float roughness = clamp(1.0 - s.smoothness, 0.045, 1.0); // perceptual, floored so GGX stays finite
    float a = roughness * roughness;
    vec3 f0 = mix(vec3(0.04), s.albedo, metallic);
    vec3 diffuse_color = s.albedo * (1.0 - metallic);

    vec3 color = vec3(0.0);
    int count = int(ambient_count.y);
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
        vec3 to_light = -L;
        float NoL = max(dot(n, to_light), 0.0);
        if (NoL <= 0.0) continue;
        float atten = light_attenuation(l, L, dist);
        if (i == int(shadow_params.w)) atten *= shadow_factor(frag_world_pos);
        vec3 h = normalize(v + to_light);
        float NoH = max(dot(n, h), 0.0);
        float VoH = max(dot(v, h), 0.0);
        vec3 F = F_Schlick(VoH, f0);
        // Times pi: the diffuse term is not divided by it, so neither is this.
        vec3 spec = D_GGX(NoH, a) * V_SmithGGXCorrelated(NoV, NoL, a) * F * PI;
        vec3 kd = (1.0 - F) * diffuse_color;
        color += (kd + spec) * l.color_outer.rgb * (NoL * atten);
    }

    // What no light reaches: the environment, shaded by occlusion.
    vec3 r = reflect(-v, n);
    vec3 irradiance = texture(env_irradiance, n).rgb * env_params.x;
    vec3 reflected = textureLod(env_specular, r, roughness * env_params.z).rgb * env_params.y;
    color += (diffuse_color * irradiance + reflected * env_brdf_approx(f0, roughness, NoV)) * s.occlusion;

    out_color = vec4(color + s.emissive, s.alpha);
}
