// The surface shader template, part 2: the lighting. Presets the Surface,
// lets surface() change it, then lights it with a lambert term per light
// from the pass's Light UBO, the way the built-in lit shader always has.

void main() {
    vec4 base = texture(tex, frag_uv) * frag_color;
    Surface s;
    s.albedo   = base.rgb;
    s.alpha    = base.a;
    s.normal   = normalize(frag_normal);
    s.emissive = vec3(0.0);
    surface(s);

    vec3 n = normalize(s.normal);
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
        if (i == int(shadow_params.w)) atten *= shadow_factor(frag_world_pos);
        light += l.color_outer.rgb * ((1.0 - ambient) * diffuse * atten);
    }

    out_color = vec4(s.albedo * light + s.emissive, s.alpha);
}
