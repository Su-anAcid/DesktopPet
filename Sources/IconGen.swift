#if ICONGEN
import AppKit
import CoreGraphics

// MARK: - 应用图标生成器
// 用像素猫坐姿渲染成 macOS 风格（超级椭圆底板 + 渐变背景 + 投影）的应用图标

// 输出目录：默认相对当前工作目录（仓库根），可用 ICON_OUT_DIR 覆盖
let iconOutDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ICON_OUT_DIR"] ?? "build/icon",
                     isDirectory: true)

/// 超级椭圆（squircle）路径，n 越大越方，macOS 图标约 n = 5
func iconSquirclePath(in rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

private func cgColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// 在 1024 逻辑坐标系里绘制完整图标（调用方已按目标尺寸缩放 CTM）
private func drawIcon(_ ctx: CGContext, pose: Frame, px: Int) {
    let pal = petPalettes[0].colors

    // 像素猫的包围盒
    var minX = 64, maxX = 0, minY = 64, maxY = 0
    for (row, line) in pose.enumerated() {
        for (col, ch) in line.enumerated() where ch != "." {
            minX = min(minX, col); maxX = max(maxX, col)
            minY = min(minY, row); maxY = max(maxY, row)
        }
    }
    let bw = CGFloat(maxX - minX + 1), bh = CGFloat(maxY - minY + 1)

    // 底板：1024 画布内 824 x 824 居中
    let board = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = iconSquirclePath(in: board)

    // 底板外投影（小尺寸省略，避免糊成一团）
    if px >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40,
                      color: cgColor(0x000000, 0.25))
        ctx.setFillColor(cgColor(0xFFFFFF))
        ctx.addPath(squircle); ctx.fillPath()
        ctx.restoreGState()
    }

    // 底板渐变背景（奶油色 → 蜜桃色）
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [cgColor(0xFFF6E7), cgColor(0xF8CBA2)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // 顶部柔光
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [cgColor(0xFFFFFF, 0.5), cgColor(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 740), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 740), endRadius: 430, options: [])

    // 猫的整数倍放大（高分辨率下保持像素方块整齐）
    let fitW: CGFloat = 824 * 0.76, fitH: CGFloat = 824 * 0.66
    let scale = max(1, min((fitW / bw).rounded(.down), (fitH / bh).rounded(.down)))
    let cw = bw * scale, chh = bh * scale
    // 视觉中心略低于几何中心，爪底落在下方
    let catBottom = 505 - chh / 2
    let ox = 512 - cw / 2

    // 地面投影（椭圆裁剪 + 径向渐变软阴影）
    let sw = cw * 1.18, sh: CGFloat = 56
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - sw / 2, y: catBottom - sh / 2 - 6, width: sw, height: sh))
    ctx.clip()
    let shadow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                            colors: [cgColor(0x5B4232, 0.34), cgColor(0x5B4232, 0.10),
                                     cgColor(0x5B4232, 0)] as CFArray,
                            locations: [0, 0.45, 1])!
    let scy = catBottom - sh / 2 - 6 + sh / 2
    ctx.drawRadialGradient(shadow, startCenter: CGPoint(x: 512, y: scy), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: scy), endRadius: sw / 2, options: [])
    ctx.restoreGState()

    // 画猫
    if let img = makeCGImage(pose, palette: pal) {
        ctx.interpolationQuality = .none
        // makeCGImage 第 0 行在顶部 → CG 坐标里放到 rect 顶部
        ctx.draw(img, in: CGRect(x: ox, y: catBottom, width: cw, height: chh))
        ctx.interpolationQuality = .default
    }
    ctx.restoreGState()
}

private func renderIconPNG(pose: Frame, px: Int, to url: URL) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let S = CGFloat(px) / 1024
    ctx.scaleBy(x: S, y: S)
    drawIcon(ctx, pose: pose, px: px)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// 主入口：候选对比图 + 正式 iconset
func generateAppIcon() {
    try? FileManager.default.createDirectory(at: iconOutDir, withIntermediateDirectories: true)

    // 1) 三候选 512px 对比图
    let candidates = ["sitA", "happyA", "loveA"]
    let cell = 512, gap = 24
    let sheetW = candidates.count * cell + (candidates.count + 1) * gap
    let sheetH = cell + 2 * gap
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(cgColor(0xE8E8EC))
    ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    for (i, name) in candidates.enumerated() {
        let ox = gap + i * (cell + gap)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(ox), y: CGFloat(gap))
        ctx.scaleBy(x: CGFloat(cell) / 1024, y: CGFloat(cell) / 1024)
        drawIcon(ctx, pose: poseFrames[name]!, px: cell)
        ctx.restoreGState()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: iconOutDir.appendingPathComponent("candidates.png"))

    // 2) 以 happyA 生成全套 iconset
    let pose = poseFrames["happyA"]!
    let iconset = iconOutDir.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let table: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (px, name) in table {
        renderIconPNG(pose: pose, px: px, to: iconset.appendingPathComponent(name))
    }
    print("ICON OK -> \(iconset.path)")
}
#endif
