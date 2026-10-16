// Screen-space ambient occlusion (the engine's scene_ssao step): how much of
// the hemisphere above each pixel's surface the scene's depth leaves open.
// The surface point and its normal come from the depth (the normal from the
// neighbour on the side whose depth is closer, so an edge does not bend
// it). Samples spread over the hemisphere around the normal, denser near the
// point, turned per pixel by interleaved gradient noise. A sample counts as
// occluded where the depth at its pixel is in front of it, weighted down the
// further that surface lies outside the radius, so a near object does not
// darken a far wall. Out: red the open fraction (1 open, 0 occluded), green
// the pixel's view depth, for the blur.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_ao;

layout(set = 2, binding = 0) uniform sampler2D depth;

layout(set = 3, binding = 1) uniform Params {
    mat4 proj;     // the camera's projection, as the depth was drawn
    mat4 inv_proj;
    vec4 params;   // x = radius (view units), y = intensity, z = sample count
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

void main() {
    size = textureSize(depth, 0);
    ivec2 p = clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1);
    if (texelFetch(depth, p, 0).r >= 1.0) {
        out_ao = vec4(1.0, 1e4, 0.0, 1.0); // the sky: open, far
        return;
    }
    vec3 c = view_pos(p);
    vec3 l = view_pos(p - ivec2(1, 0)), r = view_pos(p + ivec2(1, 0));
    vec3 u = view_pos(p - ivec2(0, 1)), b = view_pos(p + ivec2(0, 1));
    vec3 dx = abs(r.z - c.z) < abs(c.z - l.z) ? r - c : c - l;
    vec3 dy = abs(b.z - c.z) < abs(c.z - u.z) ? b - c : c - u;
    vec3 n = normalize(cross(dy, dx));
    if (dot(n, -c) < 0.0) n = -n; // toward the camera

    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    float angle = noise * 6.2831853;
    vec3 rnd = vec3(cos(angle), sin(angle), 0.0);
    vec3 t = normalize(abs(dot(rnd, n)) > 0.99 ? vec3(0.0, 1.0, 0.0) - n * n.y : rnd - n * dot(rnd, n));
    mat3 tbn = mat3(t, cross(n, t), n);

    float radius = params.x;
    int count = int(params.z + 0.5);
    float occluded = 0.0;
    for (int i = 0; i < count; ++i) {
        // Spread over the hemisphere (heights even in cos, a golden-angle
        // spiral around), nearer the point for the early samples.
        float fi = (float(i) + 0.5) / float(count);
        float z = fi;
        float ring = sqrt(1.0 - z * z);
        float phi = float(i) * 2.3999632 + noise * 6.2831853;
        vec3 h = vec3(ring * cos(phi), ring * sin(phi), z);
        float scale = mix(0.1, 1.0, fi * fi);
        vec3 s = c + tbn * h * (radius * scale);

        vec4 clip = proj * vec4(s, 1.0);
        vec2 uv = vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
        if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) continue;
        float scene_z = view_pos(ivec2(uv * vec2(size))).z;
        // In front of the sample (view z grows toward the camera), within reach.
        float reach = smoothstep(0.0, 1.0, radius / max(abs(c.z - scene_z), 1e-4));
        occluded += (scene_z >= s.z + 0.02 * radius ? 1.0 : 0.0) * reach;
    }
    float open = clamp(1.0 - params.y * occluded / float(max(count, 1)), 0.0, 1.0);
    out_ao = vec4(open, -c.z, 0.0, 1.0);
}
