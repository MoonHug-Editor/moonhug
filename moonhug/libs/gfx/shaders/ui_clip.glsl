// UI clip (the engine's UiMask): how much of a pixel is inside every mask
// above the quad being drawn. A fragment shader of a UI material multiplies
// its alpha by ui_clip():
//
//   #include "ui_clip.glsl"
//   ...
//   out_color.a *= ui_clip();
//
// The masks come with the draw, in the per-draw block (gfx Clip_Mask, set by
// gfx.draw_quad `clip`): a quad under no mask has none, and ui_clip() is 1.
// Each mask maps the pixel's place on screen into its own rect, so it holds
// for a turned mask and for a canvas in the world seen at an angle, and needs
// nothing from the vertex stage.
//
// The importer adds the include and the call to a shader by itself when the
// project's UiMask setting is Auto Inject. It then defines
// MOONHUG_UI_CLIP_AUTO, which makes a ui_clip() written by hand 1, so the
// clip is applied once.
#ifndef MOONHUG_UI_CLIP
#define MOONHUG_UI_CLIP

#define MOONHUG_CLIP_MAX 8

// The per-draw block. A shader that declares it itself (the built-in ones)
// defines MOONHUG_DRAW_UBO first. Must match gfx _Draw_Uniform.
#ifndef MOONHUG_DRAW_UBO
#define MOONHUG_DRAW_UBO
layout(set = 3, binding = 2) uniform DrawUBO {
    vec4 draw_params;
    vec4 fog_color;
    vec4 fog_params;
    vec4 fog_more;
    vec4 view_pos;
    mat4 view_proj;
    vec4 probe_pos;
    vec4 probe_min;
    vec4 probe_max;
    vec4 probe2_pos;
    vec4 probe2_min;
    vec4 probe2_max;
    vec4 probe_blend;
    uvec4 draw_layers;
    vec4 clip_count;                         // x = how many masks follow, y = the one that reads ui_clip_tex, from 1
    vec4 clip_masks[MOONHUG_CLIP_MAX * 5];   // per mask: three rows that map the pixel, its shape, its radii
};
#endif

// The texture of the draw's textured mask (gfx CLIP_SAMPLER_SLOT), white
// with none. A shader with the UI clip keeps binding 6 for it.
layout(set = 2, binding = 6) uniform sampler2D ui_clip_tex;

// How much of the pixel at `frag` (gl_FragCoord.xy) is inside every mask of
// the draw: 1 inside them all, 0 outside any, between on an edge.
float ui_clip_at(vec2 frag) {
    int count = int(clip_count.x + 0.5);
    int textured = int(clip_count.y + 0.5) - 1;
    vec2 tex_uv = vec2(0.0);
    float a = 1.0;
    for (int i = 0; i < count && i < MOONHUG_CLIP_MAX; i++) {
        int b = i * 5;
        // The pixel in the mask's own units, from its rect's centre.
        vec3 h = vec3(dot(clip_masks[b].xyz, vec3(frag, 1.0)), dot(clip_masks[b + 1].xyz, vec3(frag, 1.0)), dot(clip_masks[b + 2].xyz, vec3(frag, 1.0)));
        vec2 p = h.xy / h.z;
        vec2 half_size = clip_masks[b + 3].xy;
        float soft = clip_masks[b + 3].z;
        // Radii: top left, top right, bottom right, bottom left.
        vec4 radii = clip_masks[b + 4];
        float r = p.x > 0.0 ? (p.y > 0.0 ? radii.y : radii.z) : (p.y > 0.0 ? radii.x : radii.w);
        r = min(r, min(half_size.x, half_size.y));
        vec2 q = abs(p) - half_size + r;
        float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
        float px = max(fwidth(d), 1e-6);
        a *= soft > 0.0 ? clamp(-d / max(soft, px), 0.0, 1.0) : clamp(0.5 - d / px, 0.0, 1.0);
        // The textured mask: its uv rect (x, y, width, height from the top
        // left) is in the w of its rows and of its shape, stretched over
        // the rect.
        if (i == textured) {
            vec2 unit = vec2(p.x / (2.0 * half_size.x) + 0.5, 0.5 - p.y / (2.0 * half_size.y));
            tex_uv = vec2(clip_masks[b].w, clip_masks[b + 1].w) + unit * vec2(clip_masks[b + 2].w, clip_masks[b + 3].w);
        }
    }
    // Read after the loop: the count comes with the draw, so every pixel of
    // it takes this branch or none does.
    if (textured >= 0) a *= texture(ui_clip_tex, tex_uv).a;
    return a;
}

#ifdef MOONHUG_UI_CLIP_AUTO
#define ui_clip() 1.0
#else
#define ui_clip() ui_clip_at(gl_FragCoord.xy)
#endif

#endif
