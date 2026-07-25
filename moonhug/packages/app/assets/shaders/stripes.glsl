// PROPERTY BLOCK EXAMPLE — paints stripes over the texture.
//
// How to use:
//   1. Create a Material (Assets/Create/Material).
//   2. Set its `custom_shader` to this file — black stripes appear at once.
//   3. The material's `properties` list auto-fills with the rows below
//      (they come from the MaterialUBO members). Tweak them and watch the
//      mesh update live:
//        stripe_color  x,y,z = RGB of the stripes, w = strength (0..1)
//        stripe_count  stripes across the uv (0 falls back to 6)
//        tilt          0 = horizontal, 1 = diagonal
//
// Property rules: block at set = 3, binding = 1; members may be float/vec2/
// vec3/vec4; rows match members BY NAME; unset rows are ZERO — pick in-shader
// fallbacks for zero so the effect is visible before any tweaking.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  stripe_color;
    float stripe_count;
    float tilt;
};

layout(location = 0) out vec4 out_color;

void main() {
    vec4 base = texture(tex, frag_uv) * frag_color;

    vec4 sc = stripe_color;
    if (sc == vec4(0.0)) sc = vec4(0.0, 0.0, 0.0, 1.0); // unset: black, full strength
    float count = stripe_count <= 0.0 ? 6.0 : stripe_count;

    float wave = fract((frag_uv.y + frag_uv.x * tilt) * count);
    float stripe = step(0.5, wave);
    out_color = vec4(mix(base.rgb, sc.rgb, stripe * clamp(sc.a, 0.0, 1.0)), base.a);
}
