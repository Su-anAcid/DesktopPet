#!/bin/zsh
# 发布打包：通用二进制（Apple Silicon + Intel）→ .app → .dmg / .zip / SHA256
# 用法: ./release.sh [版本号]    例: ./release.sh 1.0.0
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
BUILD_NUMBER="$(date +%Y%m%d)"
APP_NAME="DesktopPet"
APP="build/release/$APP_NAME.app"
DIST="dist"
DMG_NAME="DesktopPet-$VERSION.dmg"
ZIP_NAME="DesktopPet-$VERSION.zip"
MIN_MACOS="11.0"

echo "▸ 发布版本 v$VERSION (build $BUILD_NUMBER)"

# ---------- 1. 图标 ----------
mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ Sources/IconGen.swift -nt build/AppIcon.icns ] || [ Sources/SpriteData.swift -nt build/AppIcon.icns ]; then
  echo "▸ 生成应用图标..."
  swiftc -O -D ICONGEN Sources/SpriteData.swift Sources/IconGen.swift Sources/main.swift -o build/icongen
  ./build/icongen
  iconutil -c icns build/icon/AppIcon.iconset -o build/AppIcon.icns
fi

# ---------- 2. 组装 app 包 ----------
rm -rf "$APP" "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"
cp -f Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp -f build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ---------- 3. 通用二进制 ----------
SRCS=(Sources/SpriteData.swift Sources/App.swift Sources/CheckIn.swift Sources/Countdown.swift Sources/ToolsPanel.swift Sources/Study.swift Sources/Bubble.swift Sources/Reminders.swift)
echo "▸ 编译 arm64 ..."
swiftc -O -target arm64-apple-macos$MIN_MACOS "${SRCS[@]}" -o build/release/pet-arm64
echo "▸ 编译 x86_64 ..."
swiftc -O -target x86_64-apple-macos$MIN_MACOS "${SRCS[@]}" -o build/release/pet-x86_64
lipo -create build/release/pet-arm64 build/release/pet-x86_64 \
     -output "$APP/Contents/MacOS/$APP_NAME"
rm -f build/release/pet-arm64 build/release/pet-x86_64
echo "  $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

# ---------- 4. 签名（ad-hoc，无开发者证书时的标准做法） ----------
codesign --force --timestamp=none -s - "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# ---------- 5. DMG（拖拽安装） ----------
echo "▸ 打包 DMG ..."
STAGE="build/release/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "桌面宠物 $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ \
        "$DIST/$DMG_NAME" >/dev/null
rm -rf "$STAGE"

# ---------- 6. ZIP（备用渠道 / 自动化用） ----------
echo "▸ 打包 ZIP ..."
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP_NAME"

# ---------- 7. 校验和 ----------
( cd "$DIST" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt )

echo ""
echo "▸ 完成，产物在 $(pwd)/$DIST"
ls -lh "$DIST"
echo ""
cat "$DIST/SHA256SUMS.txt"
