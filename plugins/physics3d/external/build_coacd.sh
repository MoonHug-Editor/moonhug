#!/bin/sh
# Builds CoACD's command line tool (the CoACD submodule beside this script),
# which the editor runs for convex decompositions, and copies it to
# bin/<os>-<arch>/coacd.
# CMake downloads CoACD's dependencies (OpenVDB, TBB, Boost, zlib, spdlog)
# into the build tree, builds/coacd at the repository root, about 1 GB.
# `mh setup` runs this. Run from the repository root.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
build="$root/builds/coacd"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
out="$here/bin/$os-$arch"

extra=""
if [ "$os" = "darwin" ]; then
	# The SDK of the active Xcode: the Command Line Tools may carry a newer
	# SDK than Xcode's linker reads.
	sdk="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
	if [ -d "$sdk" ]; then extra="-DCMAKE_OSX_SYSROOT=$sdk"; fi
fi

if [ ! -f "$here/CoACD/CMakeLists.txt" ]; then
	git -C "$root" submodule update --init --recursive plugins/physics3d/external/CoACD
fi

# CMake 4 rejects the old minimum versions in the dependencies' scripts.
cmake -S "$here/CoACD" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 $extra
cmake --build "$build" --target main -j 8

mkdir -p "$out"
cp "$build/main" "$out/coacd"
