// Temporal anti-aliasing's resolve (the engine's scene_taa step): this
// frame's image, rendered a fraction of a pixel off (a different jitter each
// frame), blended into the history of earlier frames, so over a few frames a
// pixel averages many positions inside itself: edges and highlights thinner
// than a pixel settle into a steady fringe instead of flickering.
//
// Each pixel finds where it was last frame from the nearest surface in its
// 3x3 neighbourhood (so an edge moves with what is in front): that pixel's
// motion vector where an object moved (the motion input, alpha 1), else its
// world position, from the depth, into last frame's camera. The history there is clipped to the
// spread of this frame's 3x3 neighbourhood (mean +- 1.25 standard deviations,
// in YCoCg), so what was uncovered or moved does not ghost. The history is
// read through a Catmull-Rom filter, which keeps its detail where a bilinear
// read would soften it again every frame the view moves, and this frame
// counts for more the faster the pixel moves. The blend weights each side by
// 1 / (1 + luma), so one very bright sample cannot dominate.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D current;
layout(set = 2, binding = 1) uniform sampler2D history;
layout(set = 2, binding = 2) uniform sampler2D depth;
layout(set = 2, binding = 3) uniform sampler2D motion;

layout(set = 3, binding = 1) uniform Params {
    mat4 reproject; // this frame's clip space to last frame's, both through the steady camera
    vec4 params;    // x = this frame's weight, y = 1 when the history is valid, z = 1 when `motion` holds this frame's motion vectors
};

vec3 to_ycocg(vec3 c) {
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 from_ycocg(vec3 c) {
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// The history at `uv` through a Catmull-Rom filter: 4x4 texels read in 5
// bilinear fetches, the corners left out (their weights are small).
vec3 history_catmull_rom(vec2 uv, vec2 size) {
    vec2 pos = uv * size;
    vec2 p1 = floor(pos - 0.5) + 0.5;
    vec2 f = pos - p1;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 p0 = (p1 - 1.0) / size;
    vec2 p3 = (p1 + 2.0) / size;
    vec2 p12 = (p1 + w2 / w12) / size;
    vec3 c = textureLod(history, vec2(p12.x, p0.y), 0.0).rgb * (w12.x * w0.y)
           + textureLod(history, vec2(p0.x, p12.y), 0.0).rgb * (w0.x * w12.y)
           + textureLod(history, p12, 0.0).rgb * (w12.x * w12.y)
           + textureLod(history, vec2(p3.x, p12.y), 0.0).rgb * (w3.x * w12.y)
           + textureLod(history, vec2(p12.x, p3.y), 0.0).rgb * (w12.x * w3.y);
    float w = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    // The filter's negative lobes can overshoot below zero at a hard edge.
    return max(c / w, vec3(0.0));
}

// The point where the segment from the box's centre to `c` leaves the box.
vec3 clip_to_box(vec3 c, vec3 lo, vec3 hi) {
    vec3 centre = 0.5 * (lo + hi);
    vec3 half_size = max(0.5 * (hi - lo), vec3(1e-5));
    vec3 d = c - centre;
    vec3 unit = abs(d / half_size);
    float m = max(unit.x, max(unit.y, unit.z));
    return m > 1.0 ? centre + d / m : c;
}

void main() {
    ivec2 size = textureSize(current, 0);
    ivec2 p = clamp(ivec2(frag_uv * vec2(size)), ivec2(0), size - 1);
    vec3 cur = texelFetch(current, p, 0).rgb;

    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    float nearest = 1.0;
    ivec2 nearest_p = p;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            ivec2 q = clamp(p + ivec2(x, y), ivec2(0), size - 1);
            vec3 c = to_ycocg(texelFetch(current, q, 0).rgb);
            m1 += c;
            m2 += c * c;
            float d = texelFetch(depth, q, 0).r;
            if (d < nearest) {
                nearest = d;
                nearest_p = q;
            }
        }
    }
    if (params.y < 0.5) {
        out_color = vec4(cur, 1.0);
        return;
    }

    // Where this pixel was last frame, moved as its nearest neighbour moved.
    vec2 texel = 1.0 / vec2(size);
    vec2 uv = (vec2(p) + 0.5) * texel;
    vec4 moved = params.z > 0.5 ? texelFetch(motion, nearest_p, 0) : vec4(0.0);
    vec2 prev_uv;
    bool behind = false;
    if (moved.a > 0.5) {
        prev_uv = uv - moved.xy;
    } else {
        vec2 nearest_uv = (vec2(nearest_p) + 0.5) * texel;
        vec4 prev = reproject * vec4(nearest_uv.x * 2.0 - 1.0, 1.0 - nearest_uv.y * 2.0, nearest, 1.0);
        prev_uv = vec2(prev.x / prev.w * 0.5 + 0.5, 0.5 - prev.y / prev.w * 0.5) + (uv - nearest_uv);
        behind = prev.w <= 0.0;
    }
    if (behind || prev_uv.x < 0.0 || prev_uv.y < 0.0 || prev_uv.x > 1.0 || prev_uv.y > 1.0) {
        out_color = vec4(cur, 1.0);
        return;
    }

    vec3 mean = m1 / 9.0;
    vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
    vec3 hist = history_catmull_rom(prev_uv, vec2(size));
    hist = from_ycocg(clip_to_box(to_ycocg(hist), mean - 1.25 * sigma, mean + 1.25 * sigma));

    // This frame's weight, rising to a quarter at 4 pixels of motion or more:
    // a moving image hides aliasing and shows smearing.
    float speed = length((prev_uv - uv) * vec2(size));
    float blend = mix(params.x, max(params.x, 0.25), clamp(speed / 4.0, 0.0, 1.0));
    float wc = blend / (1.0 + luma(cur));
    float wh = (1.0 - blend) / (1.0 + luma(hist));
    out_color = vec4((cur * wc + hist * wh) / (wc + wh), 1.0);
}
