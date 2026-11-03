#!/bin/bash
# 交叉编译 Windows 版桌面宠物
# 依赖 mingw-w64（x86_64-w64-mingw32-g++ / windres）；macOS 上可用 llvm-mingw 的 bin 目录。
# 精灵数据与图标已在仓库里，SKIP_EXPORT=1 时完全不需要 swift / node。
set -e
cd "$(dirname "$0")"

CXX=${CXX:-x86_64-w64-mingw32-g++}
WINDRES=${WINDRES:-x86_64-w64-mingw32-windres}
VERSION=${VERSION:-1.3.0}

if ! command -v "$CXX" >/dev/null 2>&1; then
  echo "找不到 $CXX（需要 mingw-w64 工具链）" >&2
  exit 1
fi

# ① 精灵帧：仓库里已有 assets/pet.dat；缺了才从 macOS 版绘制代码导出
if [ ! -f assets/pet.dat ]; then
  if command -v swiftc >/dev/null 2>&1; then
    echo "▸ 导出精灵帧…"
    mkdir -p build
    swiftc ../Sources/SpriteData.swift tools/main.swift -o build/exportpet
    ./build/exportpet assets/pet.dat
  else
    echo "缺少 assets/pet.dat 且没有 swiftc" >&2
    exit 1
  fi
fi

# ② 图标
if [ ! -f assets/pet.ico ]; then
  echo "▸ 生成 Windows 图标…"
  python3 tools/make_ico.py
fi

# ③ 资源 + 可执行文件
mkdir -p build
echo "▸ 编译资源…"
"$CXX" --version | head -1 || true
"$WINDRES" -I . -i src/pet.rc -O coff -o build/pet_res.o

echo "▸ 编译可执行文件…"
"$CXX" -std=c++17 -O2 -mwindows -DUNICODE -D_UNICODE -static -s \
  -o build/DesktopPet.exe \
  src/main.cpp src/store.cpp src/ui.cpp src/tools.cpp src/bubble.cpp \
  build/pet_res.o \
  -lgdiplus -lcomctl32 -lole32 -luuid -lshell32 -luser32 -lgdi32

# ④ 打包
rm -f "build/DesktopPet-${VERSION}-windows-x64.zip"
if command -v zip >/dev/null 2>&1; then
  (cd build && zip -q "DesktopPet-${VERSION}-windows-x64.zip" DesktopPet.exe)
  echo "▸ 打包: $(pwd)/build/DesktopPet-${VERSION}-windows-x64.zip"
fi

ls -lh build/DesktopPet.exe
file build/DesktopPet.exe 2>/dev/null || true
echo "完成: $(pwd)/build/DesktopPet.exe"
