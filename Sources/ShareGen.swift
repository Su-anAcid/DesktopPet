#if SHARE
import AppKit

// MARK: - 小红书/社交媒体配图生成器（3:4，1080×1440）
// 输出到 docs/share/ 下，供发帖直接用

private func shareColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

private func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

private let shareOutDir = ProcessInfo.processInfo.environment["SHARE_OUT_DIR"] ?? "docs/share"

private func writePNG(_ ctx: CGContext, _ name: String) {
    let dir = URL(fileURLWithPath: shareOutDir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("SHARE OK -> \(url.path)")
}

/// 柔和的漫画风背景：奶油 → 蜜桃渐变 + 大圆光斑 + 点点
private func drawCuteBackground(_ ctx: CGContext, w: Int, h: Int) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: cs,
                        colors: [shareColor(0xFFFDF8), shareColor(0xFFE2C6), shareColor(0xFFD3B0)] as CFArray,
                        locations: [0, 0.62, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(h)),
                           end: CGPoint(x: CGFloat(w), y: 0), options: [])

    // 左上大光斑
    let glow = CGGradient(colorsSpace: cs,
                          colors: [shareColor(0xFFFFFF, 0.85), shareColor(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 180, y: CGFloat(h) - 240), startRadius: 0,
                           endCenter: CGPoint(x: 180, y: CGFloat(h) - 240), endRadius: 520, options: [])
    // 右中暖光
    let warm = CGGradient(colorsSpace: cs,
                          colors: [shareColor(0xFFB98A, 0.30), shareColor(0xFFB98A, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(warm, startCenter: CGPoint(x: CGFloat(w) - 40, y: 430), startRadius: 0,
                           endCenter: CGPoint(x: CGFloat(w) - 40, y: 430), endRadius: 430, options: [])

    // 稀疏圆点装饰
    ctx.setFillColor(shareColor(0xFFFFFF, 0.55))
    let dots: [(CGFloat, CGFloat, CGFloat)] = [
        (940, 1240, 16), (1010, 1180, 9), (120, 700, 11), (60, 980, 7),
        (1000, 980, 12), (880, 660, 8), (200, 560, 9), (960, 520, 6),
    ]
    for (x, y, r) in dots {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}

/// 猫脚下的椭圆软投影
private func groundShadow(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, w: CGFloat) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let hh: CGFloat = w * 0.17
    ctx.saveGState()
    ctx.clip(to: CGRect(x: cx - w / 2, y: cy - hh / 2, width: w, height: hh))
    let g = CGGradient(colorsSpace: cs,
                       colors: [shareColor(0x8A5F42, 0.34), shareColor(0x8A5F42, 0)] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: w / 2, options: [])
    ctx.restoreGState()
}

/// 画一只像素猫（整数倍放大，保证像素方块整齐）
private func drawShareCat(_ ctx: CGContext, _ name: String, palette: Int,
                          at p: CGPoint, scale: CGFloat, shadow: Bool = true) {
    guard let img = makeCGImage(poseFrames[name]!, palette: petPalettes[palette].colors) else { return }
    if shadow {
        groundShadow(ctx, cx: p.x + CGFloat(GRID_W) * scale / 2,
                     cy: p.y + 8, w: CGFloat(GRID_W) * scale * 0.82)
    }
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: p.x, y: p.y,
                             width: CGFloat(GRID_W) * scale, height: CGFloat(GRID_H) * scale))
    ctx.restoreGState()
}

// MARK: 首图
func generateShareCover() {
    let W = 1080, H = 1440
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawCuteBackground(ctx, w: W, h: H)

    // 顶部标签胶囊
    let pill = CGRect(x: 72, y: 1296, width: 396, height: 68)
    ctx.setFillColor(shareColor(0x2E2724, 1))
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.fillPath()

    // 猫（先画，文字后压）
    drawShareCat(ctx, "walk1", palette: 0, at: CGPoint(x: 14, y: 200), scale: 4.0)
    drawShareCat(ctx, "sleepB", palette: 2, at: CGPoint(x: 806, y: 200), scale: 4.0)
    drawShareCat(ctx, "happyA", palette: 1, at: CGPoint(x: 232, y: 150), scale: 9.6)

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    // 胶囊文字
    NSAttributedString(string: "WorkBuddy 出品", attributes: [
        .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]).draw(at: NSPoint(x: 108, y: 1310))

    // 主标题
    NSAttributedString(string: "在工位，", attributes: [
        .font: NSFont.systemFont(ofSize: 92, weight: .bold),
        .foregroundColor: nsColor(0x2E2724),
    ]).draw(at: NSPoint(x: 72, y: 1146))

    NSAttributedString(string: "实现撸猫自由", attributes: [
        .font: NSFont.systemFont(ofSize: 118, weight: .heavy),
        .foregroundColor: nsColor(0x2E2724),
    ]).draw(at: NSPoint(x: 68, y: 986))

    // 感叹号用橘色强调
    NSAttributedString(string: "！", attributes: [
        .font: NSFont.systemFont(ofSize: 118, weight: .heavy),
        .foregroundColor: nsColor(0xF4732A),
    ]).draw(at: NSPoint(x: 792, y: 986))

    // 副标题
    NSAttributedString(string: "一只住在桌面上的像素小猫 · 会散步 / 打盹 / 撒娇 / 舔爪子", attributes: [
        .font: NSFont.systemFont(ofSize: 31, weight: .medium),
        .foregroundColor: nsColor(0x8A7365),
    ]).draw(at: NSPoint(x: 74, y: 906))

    // 爱心粒子
    "❤️".draw(at: NSPoint(x: 786, y: 742), withAttributes: [.font: NSFont.systemFont(ofSize: 52)])
    "❤️".draw(at: NSPoint(x: 862, y: 812), withAttributes: [.font: NSFont.systemFont(ofSize: 34)])
    "Z".draw(at: NSPoint(x: 1006, y: 596), withAttributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
        .foregroundColor: nsColor(0x6E5A4C, 0.55),
    ])
    "Z".draw(at: NSPoint(x: 1036, y: 646), withAttributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: nsColor(0x6E5A4C, 0.38),
    ])

    // 页脚
    NSAttributedString(string: "免费开源 · macOS / Windows 都有", attributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .medium),
        .foregroundColor: nsColor(0x9A8474, 0.9),
    ]).draw(at: NSPoint(x: 74, y: 74))

    NSGraphicsContext.restoreGraphicsState()

    writePNG(ctx, "cover-3x4.png")
}

// MARK: 功能一览（第二张图）
func generateShareFeatures() {
    let W = 1080, H = 1440
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawCuteBackground(ctx, w: W, h: H)

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    NSAttributedString(string: "它到底会干什么", attributes: [
        .font: NSFont.systemFont(ofSize: 74, weight: .heavy),
        .foregroundColor: nsColor(0x2E2724),
    ]).draw(at: NSPoint(x: 72, y: 1272))
    NSAttributedString(string: "8 个动作，全是手搓的像素帧", attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .medium),
        .foregroundColor: nsColor(0x8A7365),
    ]).draw(at: NSPoint(x: 74, y: 1226))

    NSGraphicsContext.restoreGraphicsState()

    // 2×4 卡片
    let cols = 2, rows = 4
    let cardW: CGFloat = 448, cardH: CGFloat = 236
    let gapX: CGFloat = 32, gapY: CGFloat = 26
    let left: CGFloat = 72, top: CGFloat = 1160

    let items: [(String, String, String)] = [
        ("walk1", "🚶 桌面散步", "在屏幕上自己走来走去，走到边上就掉头"),
        ("sleepB", "😴 原地打盹", "走累了直接趴下，头顶冒 Zzz"),
        ("stretchA", "🙆 伸个懒腰", "睡醒先抻一下，再慢悠悠站起来"),
        ("lickB", "🐾 舔爪子", "坐下前先舔两遍，仪式感很足"),
        ("quarterSweepA", "🧹 尾巴扫地", "坐稳之后尾巴左右扫两下"),
        ("lookL", "👀 左右张望", "起身前先看两眼，像在过马路"),
        ("loveA", "❤️ 摸摸有反应", "鼠标一摸，眼睛变爱心 + 冒爱心"),
        ("surpriseA", "😾 真实猫脸", "平时不傻笑，神态更接近真猫"),
    ]

    for (i, item) in items.enumerated() {
        let c = i % cols, r = i / cols
        let x = left + CGFloat(c) * (cardW + gapX)
        let y = top - CGFloat(r) * (cardH + gapY) - cardH

        // 卡片
        let rect = CGRect(x: x, y: y, width: cardW, height: cardH)
        ctx.setFillColor(shareColor(0xFFFFFF, 0.78))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(shareColor(0xFFFFFF, 0.9))
        ctx.setLineWidth(2)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                           cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.strokePath()

        // 缩略猫
        let small = CGPoint(x: x + 16, y: y + cardH - 168)
        drawShareCat(ctx, item.0, palette: i % 3, at: small, scale: 2.35, shadow: false)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSAttributedString(string: item.1, attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .bold),
            .foregroundColor: nsColor(0x2E2724),
        ]).draw(at: NSPoint(x: x + 172, y: y + cardH - 78))
        let desc = NSAttributedString(string: item.2, attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .regular),
            .foregroundColor: nsColor(0x8A7365),
        ])
        desc.draw(in: CGRect(x: x + 172, y: y + 34, width: cardW - 200, height: 92))
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    NSAttributedString(string: "灰虎斑 / 橘猫 / 黑猫 · 三种体型 · 三种节奏", attributes: [
        .font: NSFont.systemFont(ofSize: 27, weight: .medium),
        .foregroundColor: nsColor(0x9A8474, 0.95),
    ]).draw(at: NSPoint(x: 74, y: 62))
    NSGraphicsContext.restoreGraphicsState()

    writePNG(ctx, "features-3x4.png")
}

// MARK: vibecoding 过程图（第三张）
func generateShareProcess() {
    let W = 1080, H = 1440
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawCuteBackground(ctx, w: W, h: H)

    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)

    // 标题
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    NSAttributedString(string: "我一句代码都没写", attributes: [
        .font: NSFont.systemFont(ofSize: 76, weight: .heavy),
        .foregroundColor: nsColor(0x2E2724),
    ]).draw(at: NSPoint(x: 72, y: 1276))
    NSAttributedString(string: "全程自然语言 · 40 多轮对话 · 靠「说」搓出一只猫", attributes: [
        .font: NSFont.systemFont(ofSize: 29, weight: .medium),
        .foregroundColor: nsColor(0x8A7365),
    ]).draw(at: NSPoint(x: 74, y: 1228))
    NSGraphicsContext.restoreGraphicsState()

    let steps: [(String, String, String, Int)] = [
        ("做个桌面宠物", "第 1 版真的很丑，爱心还被窗口裁掉一半", "sitA", 0),
        ("以这张照片为原型", "换成家里的灰虎斑奶猫，终于像了", "happyA", 1),
        ("行走太丑，还比趴卧小", "重画 4 帧步态，尾巴还穿模，再退回去改", "walk1", 0),
        ("加行走↔坐下的过渡", "舔爪子、尾巴扫地、起身前左右张望", "lickB", 1),
        ("舔毛时头要跟着转", "前几版只是平移，我退回重做，改成图层旋转", "quarterStand", 2),
        ("做个 Windows 版", "交叉编译出一个单文件 exe", "loveA", 1),
    ]

    let left: CGFloat = 72
    let width: CGFloat = 936
    let top: CGFloat = 1150
    let rowH: CGFloat = 128
    let gap: CGFloat = 16

    for (i, step) in steps.enumerated() {
        let y = top - rowH - CGFloat(i) * (rowH + gap)
        let rect = CGRect(x: left, y: y, width: width, height: rowH)

        // 卡片
        ctx.setFillColor(shareColor(0xFFFFFF, 0.82))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.fillPath()

        // 序号圆点
        ctx.setFillColor(shareColor(0xF4732A, 1))
        ctx.fillEllipse(in: CGRect(x: left + 26, y: y + rowH / 2 - 23, width: 46, height: 46))

        // 右侧缩略猫
        drawShareCat(ctx, step.2, palette: step.3,
                     at: CGPoint(x: left + width - 128, y: y + rowH - 112),
                     scale: 1.72, shadow: false)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        // 序号数字
        let num = NSAttributedString(string: "\(i + 1)", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let nb = num.size()
        num.draw(at: NSPoint(x: left + 26 + (46 - nb.width) / 2, y: y + rowH / 2 - nb.height / 2 + 2))

        // 说出口的那句话
        NSAttributedString(string: "「\(step.0)」", attributes: [
            .font: NSFont.systemFont(ofSize: 31, weight: .bold),
            .foregroundColor: nsColor(0x2E2724),
        ]).draw(at: NSPoint(x: left + 92, y: y + rowH - 58))

        // 结果
        NSAttributedString(string: step.1, attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .regular),
            .foregroundColor: nsColor(0x8A7365),
        ]).draw(at: NSPoint(x: left + 94, y: y + 26))

        NSGraphicsContext.restoreGraphicsState()
    }

    // 页脚
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    NSAttributedString(string: "验收方式也很简单：让它走一圈，丑不丑一眼就知道", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .medium),
        .foregroundColor: nsColor(0x9A8474, 0.95),
    ]).draw(at: NSPoint(x: 74, y: 66))
    NSGraphicsContext.restoreGraphicsState()

    writePNG(ctx, "process-3x4.png")
}
#endif
