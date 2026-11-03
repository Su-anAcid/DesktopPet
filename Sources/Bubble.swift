import AppKit

// MARK: - 气泡视图（圆角卡片 + 一只小尾巴）
private final class BubbleView: NSView {
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var titleText = ""
    var messageText = ""
    var hintText = ""
    var tailOnTop = false
    var onTap: (() -> Void)?

    private let tailH: CGFloat = 9
    private let padX: CGFloat = 14
    private let padTop: CGFloat = 10
    private let padBottom: CGFloat = 10
    private let maxTextW: CGFloat = 236
    private let radius: CGFloat = 12

    private let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private let messageFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let hintFont = NSFont.systemFont(ofSize: 10)

    // MARK: 尺寸
    private func attributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.alignment = .left
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }

    private func measure(_ text: String, font: NSFont) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let a = NSAttributedString(string: text, attributes: attributes(font))
        let r = a.boundingRect(with: NSSize(width: maxTextW, height: 400),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(r.width), height: ceil(r.height))
    }

    func fittingSize() -> NSSize {
        let t = measure(titleText, font: titleFont)
        let m = measure(messageText, font: messageFont)
        let h = measure(hintText, font: hintFont)

        var width = max(t.width, max(m.width, h.width)) + padX * 2
        width = max(width, 128)

        var height = padTop + padBottom + m.height + tailH
        if t.height > 0 { height += t.height + 2 }
        if h.height > 0 { height += h.height + 5 }
        return NSSize(width: ceil(width), height: ceil(height))
    }

    // MARK: 绘制
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = dark
            ? NSColor(srgbRed: 0.16, green: 0.15, blue: 0.14, alpha: 0.985)
            : NSColor(srgbRed: 1.0, green: 0.985, blue: 0.955, alpha: 0.985)

        let body: NSRect
        if tailOnTop {
            body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1,
                          height: bounds.height - tailH - 0.5)
        } else {
            body = NSRect(x: 0.5, y: tailH, width: bounds.width - 1,
                          height: bounds.height - tailH - 0.5)
        }

        let card = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        let tail = NSBezierPath()
        let midX = (bounds.width / 2).rounded()
        let halfTail: CGFloat = 7
        if tailOnTop {
            tail.move(to: NSPoint(x: midX - halfTail, y: body.maxY - 1))
            tail.line(to: NSPoint(x: midX, y: bounds.maxY - 0.5))
            tail.line(to: NSPoint(x: midX + halfTail, y: body.maxY - 1))
        } else {
            tail.move(to: NSPoint(x: midX - halfTail, y: body.minY + 1))
            tail.line(to: NSPoint(x: midX, y: bounds.minY + 0.5))
            tail.line(to: NSPoint(x: midX + halfTail, y: body.minY + 1))
        }
        tail.close()

        // 先填圆角卡片再填尾巴（尾巴后填，接缝更干净）
        fill.setFill()
        card.fill()
        tail.fill()

        // 文字（尾巴在上面时，卡片顶部要让出尾巴的高度）
        var y = bounds.maxY - (tailOnTop ? tailH : 0) - padTop
        func draw(_ text: String, font: NSFont, color: NSColor, spacing: CGFloat) {
            guard !text.isEmpty else { return }
            let h = measure(text, font: font).height
            let a = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.lineBreakMode = .byWordWrapping
                    p.alignment = .left
                    return p
                }(),
            ])
            a.draw(in: NSRect(x: padX, y: y - h, width: bounds.width - padX * 2, height: h))
            y -= h + spacing
        }

        draw(titleText, font: titleFont, color: accent, spacing: 2)
        draw(messageText, font: messageFont, color: .labelColor, spacing: 0)
        if !hintText.isEmpty { y -= 5 }
        draw(hintText, font: hintFont, color: .secondaryLabelColor, spacing: 0)
    }

    // MARK: 点击
    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 猫的气泡
/// 猫头顶冒出来的一句提醒（倒计时 / 学习时长），7 秒后自己消失；点一下打开对应面板。
final class PetBubble {
    private let window: NSPanel
    private let view: BubbleView
    private var hideTimer: Timer?
    private var fadeTimer: Timer?

    var onClick: (() -> Void)?
    var isVisible: Bool { window.isVisible }

    init() {
        view = BubbleView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        window = NSPanel(contentRect: view.frame,
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // 压在猫的窗口之上（猫是 floating）
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.contentView = view

        view.onTap = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.onClick?()
        }
    }

    /// catRect 是猫在屏幕坐标里的矩形
    func show(title: String, message: String, hint: String,
              accent: NSColor, near catRect: NSRect) {
        view.accent = accent
        view.titleText = title
        view.messageText = message
        view.hintText = hint
        view.tailOnTop = false

        let size = view.fittingSize()
        layout(size: size, catRect: catRect)

        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 1
        }
        scheduleHide()
    }

    /// 猫走开了就把气泡跟着挪过去（只改位置，不改大小）
    func reposition(near catRect: NSRect) {
        guard window.isVisible else { return }
        layout(size: window.frame.size, catRect: catRect)
    }

    func dismiss() {
        hideTimer?.invalidate(); hideTimer = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window.orderOut(nil)
        }
    }

    // MARK: 内部
    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard window.isVisible else { return }
        fadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window.orderOut(nil)
        }
    }

    private func layout(size: NSSize, catRect: NSRect) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(catRect) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 尾巴尖轻搭在猫头顶上（猫的图顶部有几行透明边，往里收一点才贴得住）
        let headTop = catRect.maxY - catRect.height * 0.07
        let gap: CGFloat = 4

        var tailOnTop = false
        var y = headTop + gap
        if y + size.height > vf.maxY - 4 {
            let below = catRect.minY - gap - size.height
            if below > vf.minY + 4 {
                y = below
                tailOnTop = true
            } else {
                y = max(vf.minY + 4, vf.maxY - size.height - 4)
            }
        }
        view.tailOnTop = tailOnTop

        var x = catRect.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)

        window.setFrame(NSRect(x: x.rounded(), y: y.rounded(),
                               width: size.width, height: size.height),
                        display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
    }
}
