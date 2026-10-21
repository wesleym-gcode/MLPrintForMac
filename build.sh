#!/bin/bash
# Builds MLPrint.app (ad-hoc signed) in ./build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/ML Print for Mac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MLPrint" "$APP/Contents/MacOS/MLPrint"
cp Resources/rastertoqpdl Resources/ml2160.ppd "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ML Print for Mac</string>
  <key>CFBundleDisplayName</key><string>ML Print for Mac</string>
  <key>CFBundleIdentifier</key><string>br.local.mlprint</string>
  <key>CFBundleExecutable</key><string>MLPrint</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Documento imprimível</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>com.adobe.pdf</string><string>public.image</string><string>public.plain-text</string>
      <string>public.rtf</string><string>com.apple.rtfd</string><string>public.html</string>
      <string>org.openxmlformats.wordprocessingml.document</string><string>com.microsoft.word.doc</string>
      <string>org.oasis-open.opendocument.text</string>
    </array>
  </dict></array>
  <key>NSLocalNetworkUsageDescription</key><string>O ML Print for Mac usa a rede local para encontrar e se comunicar com a impressora.</string>
  <key>NSBonjourServices</key><array><string>_ipp._tcp</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP/Contents/Resources/rastertoqpdl"
codesign --force --deep --sign - "$APP"
echo "OK: $APP"
