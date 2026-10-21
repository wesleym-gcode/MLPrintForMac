#!/bin/bash
# Builds the splix QPDL filter (GPL v2) for this Mac and places it in Resources/,
# next to the PPD the app hands to it. Needs: Xcode Command Line Tools, git, curl.
set -euo pipefail
cd "$(dirname "$0")/.."

SPLIX_REPO="https://github.com/valdikss/splix"
SPLIX_COMMIT="c65904cddc49a06c4b2f5ccd5b82c31bd33d2872"
JBIGKIT_URL="https://www.cl.cam.ac.uk/~mgk25/jbigkit/download/jbigkit-2.1.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> jbigkit (jbig85)"
curl -fsSL "$JBIGKIT_URL" | tar xz -C "$WORK"
JBIG="$WORK/jbigkit-2.1/libjbig"
( cd "$JBIG" && cc -O2 -c jbig85.c jbig_ar.c && ar rcs libjbig85.a jbig85.o jbig_ar.o )

echo "==> splix @ $SPLIX_COMMIT"
git clone --quiet "$SPLIX_REPO" "$WORK/splix"
git -C "$WORK/splix" checkout --quiet "$SPLIX_COMMIT"
make -C "$WORK/splix" -j4 \
    CXXFLAGS="-Iinclude -I$JBIG -O2 -Wno-deprecated-declarations -std=gnu++14 -DTHREADS=4 -DCACHESIZE=50" \
    LDFLAGS="-L$JBIG -lcups -ljbig85" >/dev/null

mkdir -p Resources
cp "$WORK/splix/optimized/rastertoqpdl" Resources/rastertoqpdl
cp "$WORK/splix/ppd/ml2160.ppd" Resources/ml2160.ppd 2>/dev/null || cp "$WORK/splix/ml2160.ppd" Resources/ml2160.ppd
echo "OK: Resources/rastertoqpdl, Resources/ml2160.ppd"
