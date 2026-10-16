// Depth of field, pass 2: the half-size image blurred by each pixel's
// circle of confusion (alpha of dof_coc). Each pixel gathers `samples` taps
// on a disc of the max radius (a golden-angle spiral, turned per pixel by
// noise so the pattern does not repeat): a tap counts where its own circle
// reaches the pixel, so a blurred near object spreads over its sharp
// neighbours and a sharp object does not bleed into a blurred one behind
// it. Out: the blurred colour, alpha the pixel's circle, kept for the
// combine.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex; // dof_coc: rgb the scene at half size, a the circle of confusion in its pixels

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // x = max radius (pixels of this image), y = samples
};

void main() {
    ivec2 size = textureSize(tex, 0);
    vec2 texel = 1.0 / vec2(size);
    vec4 centre = texture(tex, frag_uv);
    float radius = params.x;
    int n = int(params.y + 0.5);
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    vec3 sum = centre.rgb;
    float weight = 1.0;
    for (int i = 0; i < n; ++i) {
        float r = radius * sqrt((float(i) + 0.5) / float(n));
        float a = float(i) * 2.3999632 + noise * 6.2831853;
        vec2 offset = vec2(cos(a), sin(a)) * r;
        vec4 s = texture(tex, frag_uv + offset * texel);
        // The tap's circle reaches this pixel, softened over a pixel: the
        // spread is the larger of the two circles, so a near blur spreads
        // over the sharp, and a far blur behind a sharp edge gathers too.
        float reach = max(abs(s.a), abs(centre.a));
        float w = clamp((reach - r + 1.0), 0.0, 1.0);
        sum += s.rgb * w;
        weight += w;
    }
    out_color = vec4(sum / weight, centre.a);
}
