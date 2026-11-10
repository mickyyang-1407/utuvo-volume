#!/bin/zsh
# UTUVO Volume 打包：轉出畫面 → 編譯（Apple 晶片＋Intel）→ 組 .app → 簽章。
# 用法：scripts/build.sh            只組 App 並簽章
#       scripts/build.sh --release  另外公證、裝訂、做 DMG（DMG 也簽＋公證＋裝訂）
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.2.1"; BUILD="3"
NAME="UTUVO Volume"; BID="app.utuvo.volume"
# 簽章身分與公證設定從環境變數來；沒設就用 ad-hoc 簽章（只能在自己的機器上跑）。
# SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="your-notarytool-profile" scripts/build.sh --release
IDENTITY="${SIGN_IDENTITY:--}"
PROFILE="${NOTARY_PROFILE:-}"
OUT="build"; APP="$OUT/$NAME.app"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

python3 scripts/make_page.py
rm -rf "$APP" "$OUT/obj"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/obj"

for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" Sources/*.swift -o "$OUT/obj/volume-$arch" 2>&1
done
lipo -create "$OUT/obj/volume-arm64" "$OUT/obj/volume-x86_64" -output "$APP/Contents/MacOS/$NAME"

# 圖示
if [ ! -f "$OUT/AppIcon.icns" ]; then
  xcrun swift scripts/make_icon.swift "$OUT/icon-1024.png"
  rm -rf "$OUT/AppIcon.iconset"; mkdir "$OUT/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$OUT/icon-1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" Resources/slider.html Resources/guide.html "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 UTUVO</string>
</dict></plist>
EOF

if [ "$IDENTITY" = "-" ]; then codesign --force --sign - "$APP"; else codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"; fi
codesign --verify --strict --deep "$APP" && echo "signed: $APP"

if [ "${1:-}" = "--release" ]; then
  [ -n "$PROFILE" ] && [ "$IDENTITY" != "-" ] || { echo "--release needs SIGN_IDENTITY and NOTARY_PROFILE"; exit 1; }
  ZIP="$OUT/notarize.zip"; DMG="$OUT/UTUVO-Volume-$VERSION-macOS.dmg"
  rm -f "$ZIP" "$DMG"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"; rm -f "$ZIP"
  STAGE="$OUT/dmg-stage"; rm -rf "$STAGE"; mkdir "$STAGE"
  ditto "$APP" "$STAGE/$NAME.app"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vv "$APP" 2>&1; spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1
  shasum -a 256 "$DMG"
fi
