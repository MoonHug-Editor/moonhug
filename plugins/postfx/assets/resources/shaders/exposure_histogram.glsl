// Auto exposure, the histogram: how much of the image falls into each of
// 256 bins of log2 luminance, over the metering range. Drawn at 16 x 16,
// one bin per texel (bin = y * 16 + x), each counting the 64 x 64 reduced
// luminance (exposure_reduce's first level: red the weighted log2 luminance
// summed, green the weight, so a texel's value is red / green and it counts
// by its weight). Out: red the weight in the bin, green the bin's log2
// luminance at its centre.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex; // the 64 x 64 reduced luminance

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x, y = the histogram's log2 luminance range (min, max)
};

void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    int bin = p.y * 16 + p.x;
    float lo = params.x, hi = params.y;
    float scale = 256.0 / max(hi - lo, 1e-4);
    ivec2 size = textureSize(tex, 0);
    float count = 0.0;
    for (int y = 0; y < size.y; ++y) {
        for (int x = 0; x < size.x; ++x) {
            vec2 t = texelFetch(tex, ivec2(x, y), 0).rg;
            float v = t.r / max(t.g, 1e-6);
            int b = clamp(int((v - lo) * scale), 0, 255);
            count += b == bin ? t.g : 0.0;
        }
    }
    out_color = vec4(count, lo + (float(bin) + 0.5) / scale, 0.0, 1.0);
}
