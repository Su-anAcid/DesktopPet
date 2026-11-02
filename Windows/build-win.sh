#!/bin/bash
# 在 macOS 上交叉编译 Windows 版桌面宠物
# 依赖二选一：
#   A) brew install mingw-w64            （走 windres 资源路线）
#   B) zig 工具链                        （数据直接编进 exe，单文件）
set -e
cd "$(dirname "$0")"

ZIG=${ZIG:-$(command -v zig || true)}

if [ "${SKIP_EXPORT:-0}" != "1" ] && command -v swiftc >/dev/null 2>&1; then
  echo "① 从 macOS 版绘制代码导出精灵帧…"
  swiftc ../Sources/SpriteData.swift tools/main.swift -o /tmp/exportpet
  /tmp/exportpet assets/pet.dat
else
  echo "① 跳过精灵导出，直接使用仓库内 assets/pet.dat（SKIP_EXPORT=1 可强制跳过）"
fi

mkdir -p build

if command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1; then
  echo "② mingw-w64：编译资源 + 可执行文件…"
  x86_64-w64-mingw32-windres -I assets -i src/pet.rc -O coff -o /tmp/pet_res.o
  x86_64-w64-mingw32-g++ -std=c++17 -O2 -mwindows -static -s \
    -o build/DesktopPet.exe src/main.cpp /tmp/pet_res.o \
    -lgdi32 -luser32 -lshell32
elif [ -x "$ZIG" ]; then
  echo "② zig：把帧数据编进 exe…"
  node tools/embed.js assets/pet.dat src/pet_data.h
  "$ZIG" c++ -target x86_64-windows-gnu -O2 -std=c++17 -DPET_EMBED \
    -Wl,--subsystem,windows \
    -o build/DesktopPet.exe src/main.cpp -lgdi32 -luser32 -lshell32
else
  echo "找不到 mingw-w64 或 zig，无法交叉编译"
  exit 1
fi

ls -lh build/DesktopPet.exe
file build/DesktopPet.exe
echo "完成: $(pwd)/build/DesktopPet.exe"
