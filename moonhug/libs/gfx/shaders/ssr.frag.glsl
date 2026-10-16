// Screen-space reflections (the engine's scene_ssr step): where each pixel's
// mirror ray lands in the view's depth, and the colour there from last
// frame's opaque image. The surface point comes from the depth, its normal
// from the normals the step drew. The ray marches in view space in `steps`
// even steps up to `max distance`, started a noise-sized fraction of a step
// in so banding becomes noise the anti-aliasing averages, and counts a hit
// where the depth's surface lies in front of the sample by less than
// `thickness`. A few halvings refine the crossing. The hit point is read in
// last frame's image through last frame's camera. Out, premultiplied: rgb
// the colour times the confidence, alpha the confidence, which fades toward
// the screen's edges, with the ray's length, and for a ray turning toward
// the camera (the screen holds little of what it sees). 0 where nothing
// reflects: the sky, a miss, a ray that left the screen or hit a back face.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D depth;
layout(set = 2, binding = 1) uniform sampler2D normals; // world space, 0 where nothing was drawn
layout(set = 2, binding = 2) uniform sampler2D scene;   // last frame's opaque image

layout(set = 3, binding = 1) uniform Params {
    mat4 proj;      // the camera's projection, as the depth was drawn
    mat4 inv_proj;
    mat4 view;      // world to view, for the normals
    mat4 reproject; // this frame's view space to last frame's clip space
    vec4 params;    // x = max distance (view units), y = thickness, z = steps, w = edge fade (fraction of the screen)
    vec4 params2;   // x = 1 when last frame's image is this view's, consecutive and the same size
};

ivec2 size;

// The view-space position of the surface at pixel `p`.
vec3 view_pos(ivec2 p) {
    p = clamp(p, ivec2(0), size - 1);
    float d = texelFetch(depth, p, 0).r;
    vec2 uv = (vec2(p) + 0.5) / vec2(size);
    vec4 v = inv_proj * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, d, 1.0);
    return v.xyz / v.w;
}

// The screen position of view-space `p`.
vec2 to_uv(vec3 p) {
    vec4 c = proj * vec4(p, 1.0);
    return vec2(c.x / c.w * 0.5 + 0.5, 0.5 - c.y / c.w * 0.5);
}

bool off_screen(vec2 uv) {
    return uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0;
}

void main() {
    out_color = vec4(0.0);
    if (params2.x < 0.5) return;
    size = textureSize(depth, 0);
    ivec2 px = clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1);
    if (texelFetch(depth, px, 0).r >= 1.0) return; // the sky
    vec3 nw = texelFetch(normals, px, 0).xyz;
    if (dot(nw, nw) < 0.25) return; // nothing drawn here (a transparent)

    vec3 p = view_pos(px);
    vec3 n = normalize(mat3(view) * normalize(nw));
    vec3 v = normalize(-p);
    vec3 r = reflect(-v, n);
    // Turning toward the camera: little of what the ray sees is on screen.
    float facing = 1.0 - smoothstep(0.0, 0.6, dot(r, v));
    if (facing <= 0.0) return;

    float max_dist = params.x;
    float thickness = params.y;
    int steps = int(params.z + 0.5);
    // Not past the near plane: a sample behind the camera has no pixel.
    float t_max = max_dist;
    if (r.z > 0.0) t_max = min(t_max, (-0.05 - p.z) / r.z);
    if (t_max <= 0.0) return;

    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    float dt = t_max / float(steps);
    float t_prev = 0.0, t = 0.0;
    bool hit = false;
    for (int i = 1; i <= steps; ++i) {
        t = dt * (float(i) + noise);
        vec3 s = p + r * t;
        vec2 uv = to_uv(s);
        if (off_screen(uv)) return;
        float dz = view_pos(ivec2(uv * vec2(size))).z - s.z; // > 0: the surface is in front of the sample
        if (dz > 0.0 && dz < thickness) { hit = true; break; }
        t_prev = t;
    }
    if (!hit) return;

    // The crossing, between the last sample in front and the hit.
    float lo = t_prev, hi = t;
    for (int i = 0; i < 5; ++i) {
        float mid = 0.5 * (lo + hi);
        vec3 m = p + r * mid;
        if (view_pos(ivec2(to_uv(m) * vec2(size))).z - m.z > 0.0) hi = mid; else lo = mid;
    }
    vec3 s = p + r * hi;
    vec2 uv = to_uv(s);
    ivec2 hp = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
    if (view_pos(hp).z - s.z > thickness) return; // behind the surface, not on it
    // A surface facing away from the ray: the ray passed behind it.
    vec3 hn = texelFetch(normals, hp, 0).xyz;
    if (dot(hn, hn) > 0.25 && dot(mat3(view) * normalize(hn), r) > 0.0) return;

    vec2 e = min(uv, 1.0 - uv);
    float edge = params.w > 0.0 ? smoothstep(0.0, params.w, min(e.x, e.y)) : 1.0;
    float reach = 1.0 - smoothstep(0.7, 1.0, hi / max_dist);
    float conf = facing * edge * reach;

    // Last frame's colour at the hit, through last frame's camera.
    vec4 pc = reproject * vec4(s, 1.0);
    if (pc.w <= 0.0) return;
    vec2 puv = vec2(pc.x / pc.w * 0.5 + 0.5, 0.5 - pc.y / pc.w * 0.5);
    if (off_screen(puv)) return;
    out_color = vec4(textureLod(scene, puv, 0.0).rgb * conf, conf);
}
