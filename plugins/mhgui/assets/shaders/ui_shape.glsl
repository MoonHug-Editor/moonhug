// Procedural shape shader (plugins/mhgui UiShape component). The quad carries no
// picture: every pixel computes its signed distance to the shape's edge, in
// canvas units, and is coloured from it. That keeps the edge one pixel soft
// at any size, radius and canvas scale, and makes the border, the gradient
// and both shadows thresholds on the same distance.
//
// The quad may be larger than the shape, to give a drop shadow room: its uvs
// run 0..1 over the whole quad, with v up.
//
// The UiShape component sets every property per draw. The fill colour is the
// vertex colour.
//   shape_size          xy: the shape's size. zw: the quad's size
//   shape_radii         corner radii: top left, top right, bottom right, bottom left
//   shape_params        x: border width. y: gradient direction, radians, 0 = left to right.
//                       z: 1 with a gradient. w: extra softness of the edge
//   border_color        the border's colour
//   gradient_color      the fill's colour at the gradient's end
//   shadow_color        the drop shadow's colour, alpha 0 = none
//   shadow_params       xy: offset. z: blur. w: spread
//   inner_shadow_color  the inner shadow's colour, alpha 0 = none
//   inner_shadow_params xy: offset. z: blur. w: spread
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 4) in vec4 frag_tangent; // under a UiMask: the clip, see ui_clip

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4 shape_size;
    vec4 shape_radii;
    vec4 shape_params;
    vec4 border_color;
    vec4 gradient_color;
    vec4 shadow_color;
    vec4 shadow_params;
    vec4 inner_shadow_color;
    vec4 inner_shadow_params;
};

layout(location = 0) out vec4 out_color;

// Signed distance from p to a box of half size `half_size` centred on the
// origin, with a radius per corner: negative inside. y is up.
float sd_round_box(vec2 p, vec2 half_size, vec4 radii) {
    float r = p.x > 0.0 ? (p.y > 0.0 ? radii.y : radii.z) : (p.y > 0.0 ? radii.x : radii.w);
    vec2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// The engine's UI clip, as in its built-in shaders (libs/gfx/shaders/world.frag.glsl).
float ui_clip(vec4 t) {
    if (t.w < 1.5) return 1.0;
    vec2 d = (1.0 - abs(t.xy)) / max(fwidth(t.xy), vec2(1e-6));
    return clamp(min(d.x, d.y) + 0.5, 0.0, 1.0);
}

// `top` drawn over `bottom`, both with straight alpha.
vec4 over(vec4 top, vec4 bottom) {
    float a = top.a + bottom.a * (1.0 - top.a);
    vec3 c = a > 0.0 ? (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / a : vec3(0.0);
    return vec4(c, a);
}

void main() {
    vec2 half_size = shape_size.xy * 0.5;
    vec2 p = (frag_uv - 0.5) * shape_size.zw;
    float limit = min(half_size.x, half_size.y);
    vec4 radii = clamp(shape_radii, 0.0, limit);

    float d = sd_round_box(p, half_size, radii);
    // One pixel in canvas units: the edge fades over it.
    float px = max(fwidth(d), 1e-5);
    float aa = px + max(shape_params.w, 0.0);
    float inside = clamp(0.5 - d / aa, 0.0, 1.0);

    // Fill, a gradient across the shape when on.
    vec4 fill = frag_color;
    if (shape_params.z > 0.5) {
        vec2 dir = vec2(cos(shape_params.y), sin(shape_params.y));
        float extent = abs(dir.x) * half_size.x + abs(dir.y) * half_size.y;
        float t = clamp(dot(p, dir) / max(extent * 2.0, 1e-5) + 0.5, 0.0, 1.0);
        fill = mix(frag_color, vec4(gradient_color.rgb, gradient_color.a * frag_color.a), t);
    }

    // Inner shadow: dark near the edge of the shape moved by the offset.
    if (inner_shadow_color.a > 0.0) {
        float di = sd_round_box(p - inner_shadow_params.xy, half_size, radii) + inner_shadow_params.w;
        float blur = max(inner_shadow_params.z, px);
        float s = smoothstep(-blur, 0.0, di);
        fill.rgb = mix(fill.rgb, inner_shadow_color.rgb, inner_shadow_color.a * s);
    }

    // Border: the band from the edge inward.
    float bw = shape_params.x;
    if (bw > 0.0 && border_color.a > 0.0) {
        float band = clamp(0.5 + (d + bw) / px, 0.0, 1.0);
        fill = mix(fill, over(border_color, fill), band);
    }

    vec4 result = vec4(fill.rgb, fill.a * inside);

    // Drop shadow, behind the shape.
    if (shadow_color.a > 0.0) {
        float ds = sd_round_box(p - shadow_params.xy, half_size, radii) - shadow_params.w;
        float blur = max(shadow_params.z, px);
        float s = 1.0 - smoothstep(-blur, blur, ds);
        result = over(result, vec4(shadow_color.rgb, shadow_color.a * s * frag_color.a));
    }
    result.a *= ui_clip(frag_tangent);
    out_color = result;
}
