// SDF text shader (packages/text2, docs/Text2.md). The quad's texture is the
// font atlas: a signed distance field with 0.5 on the glyph edge, larger
// inside. The shader thresholds it per pixel, which is what keeps text sharp
// at any size, and outline, underlay shadow and dilation are further
// thresholds and offsets on the same field.
//
// Properties (MaterialUBO members become rows on the material):
//   outline_color     rgb + a; outline_width > 0 draws it
//   outline_width     in field units (0..0.3), 0 = none
//   underlay_color    a drop shadow behind the glyphs; alpha 0 = none
//   underlay_offset   xy shift of the shadow in atlas uv units (~0.002 per px at 1024)
//   underlay_softness extra blur on the shadow edge, field units
//   softness          extra blur on the glyph edge, field units (0 = crisp)
//   dilate            grows (>0) or thins (<0) the glyph, field units
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  outline_color;
    vec4  underlay_color;
    vec2  underlay_offset;
    float outline_width;
    float underlay_softness;
    float softness;
    float dilate;
};

layout(location = 0) out vec4 out_color;

void main() {
    float sd = texture(tex, frag_uv).a;
    // Anti-aliasing width from the field's screen-space rate of change, so
    // the edge is one pixel soft at every size.
    float aa = fwidth(sd) * 0.7 + max(softness, 0.0);
    float face_edge = 0.5 - dilate;
    float face = smoothstep(face_edge - aa, face_edge + aa, sd);
    float outer_edge = face_edge - max(outline_width, 0.0);
    float shape = smoothstep(outer_edge - aa, outer_edge + aa, sd);

    vec4 ocol = outline_color;
    vec3 rgb = outline_width > 0.0 ? mix(ocol.rgb, frag_color.rgb, face) : frag_color.rgb;
    float alpha = shape * (outline_width > 0.0 ? mix(ocol.a, frag_color.a, face) : frag_color.a);
    vec4 main_col = vec4(rgb, alpha);

    // Underlay: the same field sampled at an offset, blurred, behind.
    vec4 result = main_col;
    if (underlay_color.a > 0.0) {
        float usd = texture(tex, frag_uv - underlay_offset).a;
        float uaa = aa + max(underlay_softness, 0.0);
        float ushape = smoothstep(outer_edge - uaa, outer_edge + uaa, usd);
        vec4 under = vec4(underlay_color.rgb, underlay_color.a * ushape);
        float a = main_col.a + under.a * (1.0 - main_col.a);
        vec3 c = a > 0.0 ? (main_col.rgb * main_col.a + under.rgb * under.a * (1.0 - main_col.a)) / a : vec3(0.0);
        result = vec4(c, a);
    }
    out_color = result;
}
