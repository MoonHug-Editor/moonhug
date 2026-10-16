// Auto exposure, the percentile average: the average log2 luminance of the
// part of the histogram between two percentiles, the darkest `low` share
// of the image and the brightest above `high` left out, so a black border
// or the sun does not pull the exposure. Walks the 256 bins (16 x 16, bin =
// y * 16 + x) in order, counting of each bin the part of its weight that
// lies between the two cuts. Out, 1 x 1, as exposure_reduce's last level:
// red the weighted log2 luminance summed, green the weight, for the
// adaptation to divide.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex; // the 16 x 16 histogram

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x, y = the low and high cuts, as fractions of the image (0 .. 1)
};

void main() {
    float total = 0.0;
    for (int i = 0; i < 256; ++i) total += texelFetch(tex, ivec2(i % 16, i / 16), 0).r;
    float lo = total * min(params.x, params.y);
    float hi = total * max(params.x, params.y);
    float sum = 0.0, weight = 0.0, cum = 0.0;
    for (int i = 0; i < 256; ++i) {
        vec2 bin = texelFetch(tex, ivec2(i % 16, i / 16), 0).rg;
        float start = cum;
        cum += bin.r;
        float part = clamp(cum, lo, hi) - clamp(start, lo, hi);
        sum += part * bin.g;
        weight += part;
    }
    out_color = vec4(sum, weight, 0.0, 1.0);
}
