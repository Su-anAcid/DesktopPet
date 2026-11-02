#if PREVIEW
import AppKit

// 校验网格尺寸
for (name, frame) in poseFrames {
    if frame.count != GRID_H { print("BAD ROW COUNT \(name): \(frame.count)") }
    for (i, row) in frame.enumerated() {
        if row.count != GRID_W { print("BAD LEN \(name) row\(i): \(row.count) -> '\(row)'") }
    }
}

let pixel = 7
let gap = 16
let names = ["lickA", "lickB", "lickC", "lickD"]
let frames = names.map { poseFrames[$0]! }
let sheetW = frames.count * (GRID_W * pixel) + (frames.count + 1) * gap
let sheetH = GRID_H * pixel + 2 * gap

let cgSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: sheetW, height: sheetH,
                    bitsPerComponent: 8, bytesPerRow: 0, space: cgSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(false)

func fillColor(_ c: NSColor) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
}

// 棋盘格浅色背景
for y in 0..<sheetH {
    for x in 0..<sheetW {
        let checker = ((x / (pixel * 2)) + (y / (pixel * 2))) % 2 == 0
        let gray: CGFloat = checker ? 0.90 : 0.82
        fillColor(NSColor(calibratedWhite: gray, alpha: 1))
        ctx.fill(CGRect(x: x, y: sheetH - 1 - y, width: 1, height: 1))
    }
}

// 逐帧绘制
for (fi, frame) in frames.enumerated() {
    let ox = gap + fi * (GRID_W * pixel + gap)
    let oy = gap
    for (row, line) in frame.enumerated() {
        for (col, ch) in line.enumerated() {
            guard let color = petPalettes[0].colors[ch] else { continue }
            fillColor(color)
            // PNG y 轴向下：第 0 行在最上面
            let topY = sheetH - oy - (row + 1) * pixel
            ctx.fill(CGRect(x: ox + col * pixel, y: topY, width: pixel, height: pixel))
        }
    }
}

let url = URL(fileURLWithPath: "/Users/suanacid/WorkBuddy/workspace/DesktopPet/art-preview.png")
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: url)
print("PREVIEW OK -> \(url.path)")

#endif

#if ICONGEN
generateAppIcon()
#endif

#if PROMO
generatePromo()
#endif
