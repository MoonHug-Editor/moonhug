// SPECULAR EXAMPLE — blinn-phong on top of the scene's directional Light.
// Demonstrates the view-dependent shading contract: `frag_world_pos`
// (vertex output, location 3) plus the camera position in the LightUBO.
//
// How to use:
//   1. Create a Material, set `custom_shader` to this file — a shiny
//      white highlight appears at once (fallbacks below).
//   2. Tweak the auto-filled properties:
//        spec_color  x,y,z = highlight RGB, w = strength (0..1, 0 falls back to 1)
//        shininess   highlight tightness (0 falls back to 32; try 8..256)
//   3. Orbit the scene camera — the highlight follows the view.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;
layout(location = 3) in vec3 frag_world_pos;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 light_dir_ambient; // xyz = direction light travels, w = ambient floor
    vec4 light_color;       // rgb premultiplied by intensity
    vec4 cam_pos;           // xyz = camera world position
};

layout(set = 3, binding = 1) uniform MaterialUBO {
    vec4  spec_color;
    float shininess;
};

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    vec3 to_light = -light_dir_ambient.xyz;
    vec3 to_cam   = normalize(cam_pos.xyz - frag_world_pos);

    // Same diffuse as the built-in lit shader.
    float diffuse = max(dot(n, to_light), 0.0);
    float ambient = light_dir_ambient.w;
    vec3 light = vec3(ambient) + light_color.rgb * ((1.0 - ambient) * diffuse);

    vec4 sc = spec_color;
    if (sc == vec4(0.0)) sc = vec4(1.0); // unset: white, full strength
    float shiny = shininess <= 0.0 ? 32.0 : shininess;

    // Blinn-phong: highlight where the half-vector aligns with the normal.
    vec3 half_dir = normalize(to_light + to_cam);
    float spec = pow(max(dot(n, half_dir), 0.0), shiny) * step(0.0, diffuse);

    vec4 base = texture(tex, frag_uv) * frag_color;
    vec3 rgb = base.rgb * light + light_color.rgb * sc.rgb * (spec * clamp(sc.a, 0.0, 1.0));
    out_color = vec4(rgb, base.a);
}
