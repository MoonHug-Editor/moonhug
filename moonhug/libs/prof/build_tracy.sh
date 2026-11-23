#!/bin/sh
# Builds the Tracy client (moonhug/external/tracy) into the static library
# libs/prof links when the build sets PROF to zones or all. Run by `mh` when
# the library is missing. $1 is the output file.
set -e
out="$1"
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../external/tracy/public/TracyClient.cpp"
if [ ! -f "$src" ]; then
	echo "prof: $src is missing, run: git submodule update --init moonhug/external/tracy" >&2
	exit 1
fi
mkdir -p "$(dirname "$out")"
obj="${out%.a}.o"
# TRACY_ON_DEMAND: nothing is recorded until a viewer connects.
# TRACY_ONLY_LOCALHOST: the client listens on, and announces itself to, this machine only.
# TRACY_NO_CRASH_HANDLER: the editor keeps its own (libs/crash_journal).
"${CXX:-c++}" -std=c++17 -O2 -w -c "$src" -o "$obj" \
	-DTRACY_ENABLE -DTRACY_ON_DEMAND -DTRACY_ONLY_LOCALHOST -DTRACY_NO_CRASH_HANDLER
rm -f "$out"
ar rcs "$out" "$obj"
rm -f "$obj"
