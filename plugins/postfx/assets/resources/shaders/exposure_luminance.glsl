// Auto exposure, pass 1: the scene's log2 luminance at 256 x 256. Each texel
// averages a 4 x 4 grid of filtered taps over the part of the image it
// covers, so a small bright spot counts by its area at any view size, and
// the log keeps one very bright pixel from outweighing the rest. Out: red
// the log2 luminance times the texel's metering weight, green the weight
// (centre-weighted: highest in the middle of the image, a tenth at the
// corners; average: 1 everywhere), so the reduction averages both and the
// adaptation divides.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex; // the HDR scene

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = 1 centre-weighted, 0 average
};

void main() {
    vec2 cell = 1.0 / vec2(256.0);
    vec2 corner = frag_uv - 0.5 * cell;
    float sum = 0.0;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            vec3 c = texture(tex, corner + (vec2(x, y) + 0.5) * 0.25 * cell).rgb;
            sum += log2(max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-4));
        }
    }
    vec2 d = frag_uv - 0.5;
    float w = mix(1.0, max(exp(-dot(d, d) / (2.0 * 0.25 * 0.25)), 0.1), params.x);
    out_color = vec4(sum / 16.0 * w, w, 0.0, 1.0);
}
