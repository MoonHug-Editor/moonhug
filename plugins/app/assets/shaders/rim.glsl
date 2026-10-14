// RIM LIGHT EXAMPLE — a surface shader: only surface() is written here, the
// template (libs/gfx/shaders/surface.glsl + surface_main.glsl) supplies the
// inputs, the light loop and main(). Lit like the built-in lit shader, plus a
// glow along the silhouette where the surface turns away from the camera.
//
// How to use:
//   1. Create a Material, set `custom_shader` to this file.
//   2. Tweak the auto-filled properties:
//        rim_color   rgb of the glow, w = strength (0 falls back to 1)
//        rim_power   edge tightness (0 falls back to 3; higher = thinner rim)
//
// A surface shader may declare a property block at set = 3, binding = 1 and
// extra textures at set = 2, bindings 1..7, like any user shader.

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  rim_color;
    float rim_power;
};

void surface(inout Surface s) {
    vec4 rc = rim_color;
    if (rc == vec4(0.0)) rc = vec4(1.0, 0.8, 0.4, 1.0);
    float power = rim_power <= 0.0 ? 3.0 : rim_power;

    float facing = max(dot(s.normal, view_dir()), 0.0);
    float rim = pow(1.0 - facing, power);
    s.emissive = rc.rgb * (rc.w * rim);
}
