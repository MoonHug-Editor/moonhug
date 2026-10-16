// Motion blur (the postfx_motion_blur step): each pixel smeared along how
// far it moved on screen since last frame. An object that moved carries its
// motion vector (the motion input, alpha 1 where drawn); everything else
// moved with the camera, found by reprojecting the pixel's depth through
// last frame's camera. The blur spans `intensity` of that motion, centred
// on the pixel (half before, half after, a shutter open that share of the
// frame), capped at `max blur` of the view's height, in `samples` taps
// offset per pixel by noise so the steps do not band. Each pixel gathers
// along its own motion only: a moving object blurs inside its silhouette
// and does not smear over what is behind it.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;    // the scene
layout(set = 2, binding = 1) uniform sampler2D depth;  // its depth
layout(set = 2, binding = 2) uniform sampler2D motion; // the moved objects' motion vectors (the scene, unread, when none)

layout(set = 3, binding = 1) uniform MaterialUBO {
    mat4 reproject; // this frame's clip space to last frame's, both through the steady camera
    vec4 params;    // x = intensity (the shutter's share of the frame), y = samples, z = max blur (fraction of the height), w = 1 when `motion` holds this frame's motion vectors
    vec4 params2;   // x = 1 to blur with the camera's motion, y = 1 when last frame's camera is this view's
};

// This frame's position minus last frame's, in uv units.
vec2 velocity(ivec2 p, vec2 uv) {
    vec4 moved = params.w > 0.5 ? texelFetch(motion, p, 0) : vec4(0.0);
    if (moved.a > 0.5) return moved.xy;
    if (params2.x < 0.5 || params2.y < 0.5) return vec2(0.0);
    float d = texelFetch(depth, p, 0).r;
    vec4 prev = reproject * vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, d, 1.0);
    if (prev.w <= 0.0) return vec2(0.0);
    return uv - vec2(prev.x / prev.w * 0.5 + 0.5, 0.5 - prev.y / prev.w * 0.5);
}

void main() {
    ivec2 size = textureSize(tex, 0);
    ivec2 p = clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1);
    vec3 centre = texelFetch(tex, p, 0).rgb;
    vec2 v = velocity(p, frag_uv) * params.x * vec2(size); // pixels
    float len = length(v);
    float max_px = params.z * float(size.y);
    if (len > max_px) v *= max_px / len;
    if (min(len, max_px) < 0.5) {
        out_color = vec4(centre, 1.0);
        return;
    }
    int n = int(params.y + 0.5);
    vec2 step = v / vec2(size) / float(n);
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    vec3 sum = vec3(0.0);
    float weight = 0.0;
    for (int i = 0; i < n; ++i) {
        vec2 uv = frag_uv + step * (float(i) - 0.5 * float(n - 1) + noise);
        if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) continue;
        sum += texture(tex, uv).rgb;
        weight += 1.0;
    }
    out_color = vec4(weight > 0.0 ? sum / weight : centre, 1.0);
}
