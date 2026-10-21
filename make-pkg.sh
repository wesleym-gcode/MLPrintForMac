#!/bin/bash
# Builds build/ML-Print-for-Mac-<version>.pkg (unsigned unless SIGN_ID is set to a "Developer ID Installer" identity).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
./build.sh

APP="build/ML Print for Mac.app"
WORK=build/pkg
OUT="build/ML-Print-for-Mac-$VERSION.pkg"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/root"
ditto --norsrc --noextattr "$APP" "$WORK/root/ML Print for Mac.app"
xattr -cr "$WORK/root"
codesign --verify --deep --strict "$WORK/root/ML Print for Mac.app"

# Never relocate: always install into /Applications.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/component.plist"

pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
    --install-location /Applications --identifier br.local.mlprint.pkg \
    --version "$VERSION" "$WORK/component.pkg"

SIGN=()
[ -n "${SIGN_ID:-}" ] && SIGN=(--sign "$SIGN_ID")
productbuild --distribution installer/distribution.xml --resources installer/resources \
    --package-path "$WORK" ${SIGN[@]+"${SIGN[@]}"} "$OUT"

echo "OK: $OUT"
