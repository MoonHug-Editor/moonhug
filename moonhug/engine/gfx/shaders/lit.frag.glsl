// Built-in "lit" shader: texture * color with a single directional lambert
// term. Light parameters come from the per-pass Light UBO (gfx.set_light —
// the engine feeds it from the scene's Light component, or defaults).
//
// SDL_GPU SPIR-V convention: fragment sampled textures live in set 2,
// fragment uniform buffers in set 3.
#version 450

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;
layout(location = 2) in vec3 frag_normal;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 0) uniform LightUBO {
    vec4 light_dir_ambient; // xyz = normalized direction light travels, w = ambient floor
    vec4 light_color;       // rgb premultiplied by intensity
    vec4 cam_pos;           // xyz = camera world position (unused here; specular shaders read it)
};

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(frag_normal);
    float diffuse = max(dot(n, -light_dir_ambient.xyz), 0.0);
    float ambient = light_dir_ambient.w;
    vec3 light = vec3(ambient) + light_color.rgb * ((1.0 - ambient) * diffuse);
    vec4 base = texture(tex, frag_uv) * frag_color;
    out_color = vec4(base.rgb * light, base.a);
}
