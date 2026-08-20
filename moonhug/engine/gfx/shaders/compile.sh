#!/usr/bin/env sh
# Compiles GLSL shader sources to the per-backend binaries SDL_GPU consumes:
# SPIR-V (Vulkan) via glslc, MSL (Metal) via spirv-cross. DXIL is added when
# Windows support lands.
#
# Compiled output under compiled/ is COMMITTED — contributors don't need this
# toolchain unless they change a shader. Toolchain: brew install shaderc spirv-cross
set -e
cd "$(dirname "$0")"
mkdir -p compiled

for name in world.vert world.frag lit.frag; do
    stage="${name##*.}"
    glslc "-fshader-stage=$stage" "$name.glsl" -o "compiled/$name.spv"
    # MSL entry point becomes main0 (spirv-cross convention, matches shadercross)
    spirv-cross --msl "compiled/$name.spv" --output "compiled/$name.msl"
    echo "compiled $name"
done
