// GPU skinning: one thread per vertex. Reads the bind-pose vertex and its four
// joint indices and weights, blends the joint matrices from the palette, and
// writes the posed vertex. The output has the same layout as the input so the
// ordinary mesh pipeline draws it with no shader variant.
//
// Buffers are raw uint arrays: Vertex (36 bytes) and Skin_Vertex (24 bytes,
// u16 joints + f32 weights) are not std430-expressible as structs, so each
// thread decodes its own words. See gfx/skinning.odin for the layouts.
//
// SDL_GPU SPIR-V convention for compute: set 0 = read-only storage buffers,
// set 1 = read-write storage buffers, set 2 = uniform buffers.
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(std430, set = 0, binding = 0) readonly buffer Bind    { uint bind[]; };
layout(std430, set = 0, binding = 1) readonly buffer Skin    { uint skin[]; };
layout(std430, set = 0, binding = 2) readonly buffer Palette { mat4 palette[]; };
layout(std430, set = 1, binding = 0) buffer Out              { uint posed[]; };

layout(set = 2, binding = 0) uniform Params {
    uint vertex_count;
    uint joint_count;
};

const uint VERTEX_WORDS = 13; // 3 position + 3 normal + 2 uv + 1 packed color + 4 tangent
const uint SKIN_WORDS   = 6; // 2 words of u16 joints + 4 weights

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= vertex_count) return;

    uint vb = i * VERTEX_WORDS;
    vec3 p = vec3(uintBitsToFloat(bind[vb + 0]), uintBitsToFloat(bind[vb + 1]), uintBitsToFloat(bind[vb + 2]));
    vec3 n = vec3(uintBitsToFloat(bind[vb + 3]), uintBitsToFloat(bind[vb + 4]), uintBitsToFloat(bind[vb + 5]));
    vec3 t = vec3(uintBitsToFloat(bind[vb + 9]), uintBitsToFloat(bind[vb + 10]), uintBitsToFloat(bind[vb + 11]));

    uint sb = i * SKIN_WORDS;
    uint j01 = skin[sb + 0];
    uint j23 = skin[sb + 1];
    uint joints[4] = uint[4](j01 & 0xFFFFu, j01 >> 16, j23 & 0xFFFFu, j23 >> 16);

    vec3 pos = vec3(0.0);
    vec3 nrm = vec3(0.0);
    vec3 tan = vec3(0.0);
    float total = 0.0;
    for (uint k = 0; k < 4; k++) {
        float w = uintBitsToFloat(skin[sb + 2 + k]);
        if (w <= 0.0 || joints[k] >= joint_count) continue;
        mat4 m = palette[joints[k]];
        pos += w * (m * vec4(p, 1.0)).xyz;
        nrm += w * (mat3(m) * n);
        tan += w * (mat3(m) * t);
        total += w;
    }
    // No usable weight keeps the bind pose rather than collapsing to the origin.
    if (total > 0.0) {
        p = pos / total;
        float len = length(nrm);
        n = len > 0.0 ? nrm / len : vec3(0.0);
        float tlen = length(tan);
        t = tlen > 0.0 ? tan / tlen : vec3(0.0);
    }

    posed[vb + 0] = floatBitsToUint(p.x);
    posed[vb + 1] = floatBitsToUint(p.y);
    posed[vb + 2] = floatBitsToUint(p.z);
    posed[vb + 3] = floatBitsToUint(n.x);
    posed[vb + 4] = floatBitsToUint(n.y);
    posed[vb + 5] = floatBitsToUint(n.z);
    posed[vb + 6] = bind[vb + 6];
    posed[vb + 7] = bind[vb + 7];
    posed[vb + 8] = bind[vb + 8];
    posed[vb + 9] = floatBitsToUint(t.x);
    posed[vb + 10] = floatBitsToUint(t.y);
    posed[vb + 11] = floatBitsToUint(t.z);
    posed[vb + 12] = bind[vb + 12]; // the handedness sign
}
