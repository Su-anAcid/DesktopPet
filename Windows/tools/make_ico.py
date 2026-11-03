#!/usr/bin/env python3
"""把 macOS 的 iconset PNG 打成一个 Windows .ico（PNG 压缩，Vista+ 支持）。

用法：python3 tools/make_ico.py [iconset 目录]
默认取 ../build/icon/AppIcon.iconset（先跑一次 macOS 的 build.sh 生成）。
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # Windows/
OUT = os.path.join(ROOT, "assets", "pet.ico")
SIZES = [16, 32, 48, 64, 128, 256]


def find_iconset():
    if len(sys.argv) > 1:
        return sys.argv[1]
    candidates = [
        os.path.join(ROOT, "..", "build", "icon", "AppIcon.iconset"),
        os.path.join(ROOT, "..", "dist", "icon", "AppIcon.iconset"),
    ]
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[0]


def main():
    src = find_iconset()
    images = []
    for size in SIZES:
        path = os.path.join(src, "icon_%dx%d.png" % (size, size))
        if not os.path.exists(path):
            continue
        with open(path, "rb") as f:
            images.append((size, f.read()))
    if not images:
        print("找不到图标 PNG，先运行 macOS 的 ./build.sh 生成 iconset", file=sys.stderr)
        return 1

    count = len(images)
    header = struct.pack("<HHH", 0, 1, count)
    offset = 6 + 16 * count
    entries, blobs = b"", b""
    for size, data in images:
        dim = 0 if size >= 256 else size          # 256 在 ICO 里记作 0
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(header + entries + blobs)
    print("已写入 %s（%d 个尺寸，%d 字节）" % (OUT, count, os.path.getsize(OUT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
