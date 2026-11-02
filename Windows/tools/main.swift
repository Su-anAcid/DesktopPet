// 帧数据导出器：把 macOS 版的全部精灵帧 + 3 套毛色导出成 Windows 端可读的二进制
// 这样两边的美术完全来自同一份绘制代码，不用在 C++ 里重写一遍像素画
//
// 编译：swiftc ../DesktopPet/Sources/SpriteData.swift main.swift -o /tmp/exportpet
// 运行：/tmp/exportpet ../assets/pet.dat

import AppKit

func u8(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

func round8(_ v: CGFloat) -> UInt8 { u8(Int((v * 255).rounded())) }

// 1. 收集所有用到的字符，固定成一张字符表
var alphabet: [Character] = [".", "k", "o", "d", "w", "p", "g", "s", "l", "h", "r", "m"]
var alphabetSet = Set(alphabet)
for (_, frame) in poseFrames {
    for row in frame {
        for ch in row where !alphabetSet.contains(ch) {
            alphabet.append(ch)
            alphabetSet.insert(ch)
        }
    }
}
for palette in petPalettes {
    for ch in palette.colors.keys where !alphabetSet.contains(ch) {
        alphabet.append(ch)
        alphabetSet.insert(ch)
    }
}
let indexOf: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

// 2. 帧按名字排序，保证每次导出结果稳定
let names = poseFrames.keys.sorted()
print("导出 \(names.count) 帧，字符表 \(alphabet.count) 个")

var out = Data()
func write(_ s: String) { out.append(s.data(using: .utf8)!) }
func writeU8(_ v: Int) { out.append(u8(v)) }
func writeU16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
func writeU32(_ v: Int) {
    out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
}
func writeName(_ s: String) {
    let bytes = Array(s.utf8)
    writeU8(bytes.count)
    out.append(contentsOf: bytes)
}

write("PXP1")
writeU8(GRID_W)
writeU8(GRID_H)
writeU8(alphabet.count)
for ch in alphabet { out.append(contentsOf: Array(String(ch).utf8)) }

writeU16(names.count)
for name in names {
    guard let frame = poseFrames[name] else { continue }
    writeName(name)
    for row in frame {
        let chars = Array(row)
        var line = [UInt8](repeating: 0, count: GRID_W)
        for x in 0..<GRID_W {
            let ch = x < chars.count ? chars[x] : "."
            line[x] = u8(indexOf[ch] ?? 0)
        }
        out.append(contentsOf: line)
    }
}

// 3. 调色板（按字符表顺序给 RGBA，透明字符 alpha = 0）
writeU8(petPalettes.count)
for palette in petPalettes {
    writeName(palette.name)
    for ch in alphabet {
        if ch == "." {
            out.append(contentsOf: [0, 0, 0, 0])
            continue
        }
        let color = palette.colors[ch]?.usingColorSpace(.sRGB)
        out.append(round8(color?.redComponent ?? 0))
        out.append(round8(color?.greenComponent ?? 0))
        out.append(round8(color?.blueComponent ?? 0))
        out.append(255)
    }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../assets/pet.dat"
let url = URL(fileURLWithPath: path)
try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try! out.write(to: url)
print("已写入 \(url.path)（\(out.count) 字节）")
