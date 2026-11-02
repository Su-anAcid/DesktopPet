#if PROMO
import AppKit

// MARK: - README 宣传图生成器（docs/hero.png）

private func promoCGColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func generatePromo() {
    let W = 1600, H = 1000
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // 深蓝紫渐变壁纸 + 右上柔光
    let bg = CGGradient(colorsSpace: cs,
                        colors: [promoCGColor(0.13, 0.15, 0.24), promoCGColor(0.27, 0.20, 0.36)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(W), y: CGFloat(H)), options: [])
    let glow = CGGradient(colorsSpace: cs,
                          colors: [promoCGColor(1, 1, 1, 0.14), promoCGColor(1, 1, 1, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 1250, y: 830), startRadius: 0,
                           endCenter: CGPoint(x: 1250, y: 830), endRadius: 480, options: [])

    // 猫脚下软阴影
    func groundShadow(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat) {
        let h: CGFloat = 44
        ctx.saveGState()
        ctx.clip(to: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        let g = CGGradient(colorsSpace: cs,
                           colors: [promoCGColor(0, 0, 0, 0.4), promoCGColor(0, 0, 0, 0)] as CFArray,
                           locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: w / 2, options: [])
        ctx.restoreGState()
    }

    // 画一只像素猫（整数倍放大）
    func drawCat(_ name: String, palette: Int, at p: CGPoint, scale: CGFloat) {
        guard let img = makeCGImage(poseFrames[name]!, palette: petPalettes[palette].colors) else { return }
        groundShadow(p.x + CGFloat(GRID_W) * scale / 2, p.y + 10, CGFloat(GRID_W) * scale * 0.9)
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: p.x, y: p.y, width: CGFloat(GRID_W) * scale,
                                 height: CGFloat(GRID_H) * scale))
        ctx.interpolationQuality = .default
    }

    drawCat("walk1", palette: 0, at: CGPoint(x: 130, y: 140), scale: 7)      // 灰虎斑散步
    drawCat("loveA", palette: 1, at: CGPoint(x: 650, y: 150), scale: 6.6)    // 橘猫被摸
    drawCat("sleepB", palette: 2, at: CGPoint(x: 1180, y: 140), scale: 6.2)  // 黑猫打盹

    // 右上角应用图标（柔光正落在它身上）
    if let iconImg = NSImage(contentsOfFile:
        "/Users/suanacid/WorkBuddy/workspace/DesktopPet/build/icon/AppIcon.iconset/icon_512x512.png"),
       let tiff = iconImg.tiffRepresentation,
       let cg = NSBitmapImageRep(data: tiff)?.cgImage {
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 1245, y: 745, width: 210, height: 210))
        ctx.interpolationQuality = .default
    }

    // 用 NSAttributedString 画文字与表情粒子
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

        let title = NSAttributedString(string: "桌面宠物 DesktopPet", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        title.draw(at: NSPoint(x: 90, y: H - 190))

        let sub = NSAttributedString(string: "一只住在 macOS 桌面上的像素小猫 · 散步 / 打盹 / 伸懒腰 / 舔爪子 / 摸摸有爱心眼",
                                     attributes: [
            .font: NSFont.systemFont(ofSize: 26),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.75),
        ])
        sub.draw(at: NSPoint(x: 92, y: H - 240))

        // 粒子：橘猫头顶爱心、黑猫头顶 Zzz
        "❤️".draw(at: NSPoint(x: 830, y: 590), withAttributes: [.font: NSFont.systemFont(ofSize: 42)])
        "❤️".draw(at: NSPoint(x: 915, y: 650), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
        "Z".draw(at: NSPoint(x: 1395, y: 495), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.85),
        ])
        "Z".draw(at: NSPoint(x: 1440, y: 545), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.55),
        ])

        NSGraphicsContext.restoreGraphicsState()

    let url = URL(fileURLWithPath: "/Users/suanacid/WorkBuddy/workspace/DesktopPet/docs/hero.png")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("PROMO OK -> \(url.path)")
}
#endif
