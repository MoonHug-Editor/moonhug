#!/bin/sh
# A stand-in for CoACD in the tests of the editor's decomposition jobs
# (mesh_decomposition_tests.odin): writes the U fixture's three hulls, its
# bar and two posts, to the -o file at once, and one log line the stage
# reader knows. The real tool runs in one test only.
out=""
while [ $# -gt 0 ]; do
	if [ "$1" = "-o" ]; then out="$2"; shift; fi
	shift
done
echo "[CoACD] [info] iter 0 ---- waiting pool: 1"
box() {
	echo "o convex_$1"
	for x in $2 $3; do for y in $4 $5; do for z in -0.5 0.5; do echo "v $x $y $z"; done; done; done
}
{
	box 0 -1.5 1.5 -1.5 -0.5
	box 1 -1.5 -0.5 -0.5 1.5
	box 2 0.5 1.5 -0.5 1.5
} > "$out"
