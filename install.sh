#!/bin/bash
# 桌面宠物 · macOS 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/Su-anAcid/DesktopPet/main/install.sh | bash
set -e

REPO="Su-anAcid/DesktopPet"
APP_NAME="DesktopPet.app"
DEST="/Applications"

echo "▸ 查询最新版本..."
TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
[ -n "$TAG" ] || { echo "✗ 无法获取最新版本号，请检查网络或仓库地址"; exit 1; }
VERSION="${TAG#v}"
URL="https://github.com/$REPO/releases/download/$TAG/DesktopPet-$VERSION.dmg"
echo "  最新版本 $TAG"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▸ 下载 $URL ..."
curl -fSL --progress-bar -o "$TMP/DesktopPet.dmg" "$URL"

echo "▸ 挂载并安装到 $DEST ..."
MOUNT=$(hdiutil attach "$TMP/DesktopPet.dmg" -nobrowse -readonly | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)
# 覆盖旧版本
[ -d "$DEST/$APP_NAME" ] && rm -rf "$DEST/$APP_NAME"
cp -R "$MOUNT/$APP_NAME" "$DEST/"
hdiutil detach "$MOUNT" -quiet

echo "▸ 清除隔离属性（免右键打开）..."
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

echo "▸ 启动..."
open "$DEST/$APP_NAME"
echo "✔ 安装完成，小猫已上岗。右键它即可打开设置菜单。"
