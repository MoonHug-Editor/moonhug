// Depth of field, pass 3: the sharp scene where the circle of confusion is
// under a pixel, the blurred half-size image where it is wide, blended in
// between. The blur is read in a 4-tap tent (half a texel out), which hides
// its sampling noise. The circle comes from the blur's alpha.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D tex;  // the scene, full size
layout(set = 2, binding = 1) uniform sampler2D blur; // dof_bokeh

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 params; // unused
};

void main() {
    vec3 sharp = texture(tex, frag_uv).rgb;
    vec2 texel = 1.0 / vec2(textureSize(blur, 0));
    vec4 b = texture(blur, frag_uv + vec2(-0.5, -0.5) * texel)
           + texture(blur, frag_uv + vec2( 0.5, -0.5) * texel)
           + texture(blur, frag_uv + vec2(-0.5,  0.5) * texel)
           + texture(blur, frag_uv + vec2( 0.5,  0.5) * texel);
    b *= 0.25;
    // Fully blurred from two pixels of circle (one of the half image).
    float t = smoothstep(0.5, 2.0, abs(b.a));
    out_color = vec4(mix(sharp, b.rgb, t), 1.0);
}
