#!/bin/bash
# Builds LAME (MP3 encoder) as a static library for iOS arm64 and wires it into
# the Xcode build via Configs/ThirdParty.xcconfig + a Clang module map, so the
# app can `import LAME`. Run on macOS (CI) BEFORE `xcodegen generate`.
# LAME is LGPL — see LICENSES.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ThirdParty/lame"
DL="$ROOT/ThirdParty/downloads"
VERSION=3.100
URL="https://downloads.sourceforge.net/project/lame/lame/$VERSION/lame-$VERSION.tar.gz"

mkdir -p "$DL" "$OUT/lib" "$OUT/include/lame"

cd "$DL"
if [ ! -f "lame-$VERSION.tar.gz" ]; then
  curl -L --retry 3 --fail -o "lame-$VERSION.tar.gz" "$URL"
fi
rm -rf "lame-$VERSION"
tar xzf "lame-$VERSION.tar.gz"
cd "lame-$VERSION"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0 -O3 -Wno-implicit-function-declaration"
export LDFLAGS="-arch arm64 -isysroot $SDK"

./configure --host=arm-apple-darwin \
  --disable-shared --enable-static \
  --disable-frontend --disable-decoder --disable-analyzer-hooks \
  --quiet

make -C libmp3lame -j"$(sysctl -n hw.ncpu)" >/dev/null

cp libmp3lame/.libs/libmp3lame.a "$OUT/lib/liblame.a"
cp include/lame.h "$OUT/include/lame/lame.h"

cat > "$OUT/include/module.modulemap" <<'EOF'
module LAME {
    header "lame/lame.h"
    link "lame"
    export *
}
EOF

XCCONFIG="$ROOT/Configs/ThirdParty.xcconfig"
if ! grep -q "ThirdParty/lame" "$XCCONFIG"; then
  cat >> "$XCCONFIG" <<'EOF'
SWIFT_INCLUDE_PATHS = $(SRCROOT)/ThirdParty/lame/include
LIBRARY_SEARCH_PATHS = $(inherited) $(SRCROOT)/ThirdParty/lame/lib
OTHER_LDFLAGS = $(inherited) -llame
EOF
fi

echo "LAME built: $OUT/lib/liblame.a"
