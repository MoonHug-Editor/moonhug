// Auto exposure, the adaptation: the exposure that brings the scene's
// average luminance to the target (its average log2 luminance clamped to the
// metering range; the target's log2 with the compensation added), reached over time from last frame's
// the way an eye adapts: quicker toward a brighter scene than a darker one.
// Out, 1 x 1: red the exposure to multiply by, green its log2 (next frame's
// history), blue the average log2 luminance measured.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D average; // 1 x 1, red the weighted log2 luminance's average, green the weights
layout(set = 2, binding = 1) uniform sampler2D history; // 1 x 1, last frame's output

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = seconds since last frame, y = 1 when the history is valid, z = log2 of the target plus the compensation (EV), w unused
    vec4 limits; // x, y = the average log2 luminance metered (min, max), z = speed toward a brighter scene, w = toward a darker one
};

void main() {
    vec2 m = texelFetch(average, ivec2(0), 0).rg;
    float avg = clamp(m.r / max(m.g, 1e-6), limits.x, limits.y);
    float target = params.z - avg;
    float ev = target;
    if (params.y > 0.5) {
        float prev = texelFetch(history, ivec2(0), 0).g;
        // A brighter scene lowers the exposure.
        float speed = target < prev ? limits.z : limits.w;
        ev = prev + (target - prev) * (1.0 - exp(-params.x * speed));
    }
    out_color = vec4(exp2(ev), ev, avg, 1.0);
}
