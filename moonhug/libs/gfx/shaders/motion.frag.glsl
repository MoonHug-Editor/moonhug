// Motion vectors (the engine's motion_vectors step): for each pixel of an
// object that moved since the view's last frame, how far its surface point
// moved on screen, in uv units (this frame's position minus last frame's),
// both through the steady cameras. Alpha 1 marks the pixels written: the rest
// moved only with the camera, which the TAA resolve reprojects from depth.
#version 450

layout(location = 3) in vec3 frag_world_pos;
layout(location = 0) out vec4 out_motion;

layout(set = 3, binding = 1) uniform Motion {
    mat4 to_prev;        // this object's world space now to last frame's: prev_model * inverse(model)
    mat4 view_proj;      // this frame's steady camera
    mat4 prev_view_proj; // last frame's steady camera
};

vec2 to_uv(vec4 clip) {
    return vec2(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5);
}

void main() {
    vec4 world = vec4(frag_world_pos, 1.0);
    out_motion = vec4(to_uv(view_proj * world) - to_uv(prev_view_proj * (to_prev * world)), 0.0, 1.0);
}
