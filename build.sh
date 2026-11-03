#!/bin/zsh
# 开发构建：编译当前架构的 app 并启动（产物在 build/DesktopPet.app）
set -e
cd "$(dirname "$0")"

VERSION="1.3.0"
APP="build/DesktopPet.app"

mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. 应用图标：图标源码有更新或 icns 缺失时重新生成
if [ ! -f build/AppIcon.icns ] || [ Sources/IconGen.swift -nt build/AppIcon.icns ] || [ Sources/SpriteData.swift -nt build/AppIcon.icns ]; then
  echo "▸ 生成应用图标..."
  swiftc -O -D ICONGEN Sources/SpriteData.swift Sources/IconGen.swift Sources/main.swift -o build/icongen
  ./build/icongen
  iconutil -c icns build/icon/AppIcon.iconset -o build/AppIcon.icns
fi
cp -f build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 2. Info.plist（版本号在此注入）
cp -f Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date +%Y%m%d)" "$APP/Contents/Info.plist"

# 3. 主程序
echo "▸ 编译主程序..."
swiftc -O Sources/SpriteData.swift Sources/App.swift \
    Sources/CheckIn.swift Sources/Countdown.swift Sources/ToolsPanel.swift \
    Sources/Study.swift Sources/Bubble.swift Sources/Reminders.swift \
    -o "$APP/Contents/MacOS/DesktopPet"

# 4. 本地签名（ad-hoc）
codesign --force -s - "$APP" 2>/dev/null || true

echo "▸ 构建完成: $(pwd)/$APP"
pkill -x DesktopPet 2>/dev/null || true
sleep 0.4
open "$APP"
