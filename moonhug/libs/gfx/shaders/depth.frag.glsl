// Depth only, no color and no clipping: what an unclipped mesh draws with in
// a depth pass (gfx Target_Format.Depth: shadow casters, the depth prepass).
// One shader for every such mesh, so their draws merge whatever material
// they have.
#version 450

void main() {}
