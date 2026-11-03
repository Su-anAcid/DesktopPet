#if !PREVIEW
import AppKit

// MARK: - 宠物视图
final class PetView: NSView {
    var petCG: CGImage?
    var artPixel: CGFloat = 5        // 每个艺术像素占多少 pt（×backingScale 必为整数）
    var dragEnabled = true          // 固定位置时关闭拖动
    var onPat: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = petCG, let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = .none
        ctx.shouldAntialias = false
        ctx.cgContext.interpolationQuality = .none
        ctx.cgContext.setShouldAntialias(false)

        let scale = window?.backingScaleFactor ?? 2
        let w = CGFloat(cg.width) * artPixel
        let h = CGFloat(cg.height) * artPixel
        // 关键：把绘制原点吸附到物理像素边界，避免半像素采样把方块画成一宽一窄
        let x = ((bounds.midX - w / 2) * scale).rounded() / scale
        let y = ((bounds.midY - h / 2) * scale).rounded() / scale
        ctx.cgContext.draw(cg, in: CGRect(x: x, y: y, width: w, height: h))
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        guard dragEnabled else {
            onPat?()                // 固定时点击仍是撸猫
            return
        }
        let start = win.frame.origin
        win.performDrag(with: event)   // 阻塞直到松开鼠标
        let end = win.frame.origin
        onDragEnd?()
        if abs(end.x - start.x) < 3 && abs(end.y - start.y) < 3 {
            onPat?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = menuProvider?() ?? NSMenu()
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
}

// MARK: - 漂浮小粒子（爱心 / Zzz / 📌）
final class FloatParticle: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, fontSize: CGFloat) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.sizeToFit()
        frame = NSRect(origin: .zero,
                       size: NSSize(width: max(label.frame.width, 12),
                                    height: max(label.frame.height, 14)))
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func floatUp(in parent: NSView, from point: NSPoint) {
        setFrameOrigin(point)
        parent.addSubview(self)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 1.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(NSPoint(x: point.x, y: point.y + 46))
            animator().alphaValue = 0
        }, completionHandler: { self.removeFromSuperview() })
    }
}

// MARK: - 偏好设置键
enum PrefKey {
    static let palette = "paletteIndex"
    static let size = "sizeIndex"
    static let tempo = "tempoIndex"
    static let pinned = "pinned"
    static let lick = "lickBeforeSit"
    static let originX = "panelX"
    static let originY = "panelY"
}

// MARK: - 开机自动启动（LaunchAgent）
enum LoginItem {
    static let label = "com.workbuddy.desktoppet"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// 只在以 .app 形式运行时可注册（从源码直接跑二进制时忽略）
    static var isAvailable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    static func setEnabled(_ on: Bool) {
        let fm = FileManager.default
        if on {
            guard isAvailable else { return }
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "ProcessType": "Interactive",
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            (dict as NSDictionary).write(to: plistURL, atomically: true)
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}

// MARK: - 控制器
final class PetController: NSObject {
    enum PetState { case walking, idle, sleeping, stretching, transition }

    static let panelW: CGFloat = 344
    static let panelH: CGFloat = 412      // 比猫高出一截，给爱心/Z 留上浮空间
    static let basePixel: CGFloat = 5     // 64 格 × 5pt = 320pt（100% 大小）
    static let petY: CGFloat = 10
    static let speed: CGFloat = 50        // pt/s

    let panel: NSPanel
    let petView: PetView

    private var state: PetState = .idle
    private var facing: CGFloat = 1          // 1 朝右, -1 朝左
    private var ticksLeft = 120
    private var tickCount = 0
    private var paletteIndex = 0
    private var isPinned = false             // 固定位置：仅禁用拖动，动作照常
    private var lickEnabled = true           // 坐下前舔爪子
    private var sizeIndex = 2                // 0 小 / 1 中 / 2 大
    private var loveTicks = 0                // 爱心眼持续时间
    private var happyTicks = 0               // 开心表情持续时间
    private var stretchNext: PetState = .walking   // 伸完懒腰接什么状态
    private var imageCache: [String: CGImage] = [:]
    private var timer: Timer?
    private var lastBackingScale: CGFloat = 0
    private var savedOrigin: NSPoint?

    // 过渡动画时间轴
    private var transSeq: [(String, Int)] = []
    private var transIdx = 0
    private var transLeft = 0
    private var nextAfterTrans: PetState = .idle
    private var tempoIndex = 1               // 0 慢 / 1 正常 / 2 快
    private let tempoScales: [Double] = [1.35, 1.0, 0.75]
    private var tempoScale: Double { tempoScales[tempoIndex] }

    // 缩放档位：选在 2x 屏上正好落成整数物理像素（6 / 8 / 10 px per art pixel）
    private let sizeScales: [CGFloat] = [0.6, 0.8, 1.0]

    /// 屏幕物理像素倍率（Retina 为 2）
    private var backingScale: CGFloat {
        let s = panel.backingScaleFactor
        return s > 0 ? s : (NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// 指定档位下「每个艺术像素」占用的物理像素个数（取整，保证比例不失真）
    private func devicePixel(for index: Int) -> CGFloat {
        max(1, (Self.basePixel * sizeScales[index] * backingScale).rounded())
    }

    private var pixelDevicePx: CGFloat { devicePixel(for: sizeIndex) }
    private var pixelSize: CGFloat { pixelDevicePx / backingScale }   // pt per art pixel
    private var petSize: CGFloat { CGFloat(GRID_W) * pixelSize }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelW, height: Self.panelH),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        petView = PetView(frame: NSRect(x: 0, y: Self.petY, width: 320, height: 320))
        super.init()
        loadPrefs()
        setupPanel()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.savePrefs()
        }
    }

    // MARK: 偏好读写
    private func loadPrefs() {
        let d = UserDefaults.standard
        // 用 object(forKey:) 判断「是否存过」，避免 integer(forKey:) 的 0 歧义
        if let v = d.object(forKey: PrefKey.palette) as? Int {
            paletteIndex = min(max(v, 0), petPalettes.count - 1)
        }
        if let v = d.object(forKey: PrefKey.size) as? Int {
            sizeIndex = min(max(v, 0), sizeScales.count - 1)
        }
        if let v = d.object(forKey: PrefKey.tempo) as? Int {
            tempoIndex = min(max(v, 0), tempoScales.count - 1)
        }
        if let v = d.object(forKey: PrefKey.pinned) as? Bool { isPinned = v }
        if let v = d.object(forKey: PrefKey.lick) as? Bool { lickEnabled = v }
        if let x = d.object(forKey: PrefKey.originX) as? Double,
           let y = d.object(forKey: PrefKey.originY) as? Double {
            savedOrigin = NSPoint(x: x, y: y)
        }
    }

    private func savePrefs() {
        let d = UserDefaults.standard
        d.set(paletteIndex, forKey: PrefKey.palette)
        d.set(sizeIndex, forKey: PrefKey.size)
        d.set(tempoIndex, forKey: PrefKey.tempo)
        d.set(isPinned, forKey: PrefKey.pinned)
        d.set(lickEnabled, forKey: PrefKey.lick)
        d.set(Double(panel.frame.origin.x), forKey: PrefKey.originX)
        d.set(Double(panel.frame.origin.y), forKey: PrefKey.originY)
    }

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelW, height: Self.panelH))
        panel.contentView = content
        content.addSubview(petView)
        layoutPetView()
        petView.onPat = { [weak self] in self?.pat() }
        petView.onDragEnd = { [weak self] in
            self?.clampIntoScreen()
            self?.savePrefs()
        }
        petView.dragEnabled = !isPinned      // 恢复上次的「固定位置」状态
        petView.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
    }

    func start() {
        lastBackingScale = backingScale
        if let o = savedOrigin, isOriginUsable(o) {
            setPanelOrigin(o)
            panel.makeKeyAndOrderFront(nil)
        } else {
            positionAtBottomRight()
        }
        layoutPetView()
        updateImage()

        // 防止 App Nap 节流动画
        ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                              reason: "DesktopPet animation")

        timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: 布局
    private func layoutPetView() {
        let s = petSize
        let scale = backingScale
        let x = ((Self.panelW - s) / 2 * scale).rounded() / scale
        let y = (Self.petY * scale).rounded() / scale
        petView.artPixel = pixelSize
        petView.frame = NSRect(x: x, y: y, width: s, height: s)
    }

    /// 窗口位置也吸附到物理像素，避免整只猫被半像素平移拖出「发虚/分格」
    private func setPanelOrigin(_ p: NSPoint) {
        let scale = backingScale
        panel.setFrameOrigin(NSPoint(x: (p.x * scale).rounded() / scale,
                                     y: (p.y * scale).rounded() / scale))
    }

    private var visibleFrame: NSRect {
        panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func positionAtBottomRight() {
        let vf = visibleFrame
        setPanelOrigin(NSPoint(x: vf.maxX - Self.panelW - 60, y: vf.minY + 8))
        panel.makeKeyAndOrderFront(nil)
    }

    private func clampIntoScreen() {
        let vf = visibleFrame
        var o = panel.frame.origin
        o.x = min(max(o.x, vf.minX), vf.maxX - Self.panelW)
        o.y = min(max(o.y, vf.minY), vf.maxY - Self.panelH)
        setPanelOrigin(o)
    }

    /// 上次的位置是否还落在某块屏幕里（外接屏拔掉后要能回落到主屏）
    private func isOriginUsable(_ p: NSPoint) -> Bool {
        let r = NSRect(x: p.x, y: p.y, width: Self.panelW, height: Self.panelH)
        let probe = r.insetBy(dx: r.width * 0.3, dy: r.height * 0.35)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(probe) }
    }

    // MARK: 状态机
    private func tick() {
        // 换到不同缩放的显示器时重新对齐像素网格
        if lastBackingScale != backingScale {
            lastBackingScale = backingScale
            layoutPetView()
            updateImage()
        }
        tickCount += 1
        ticksLeft -= 1
        if loveTicks > 0 { loveTicks -= 1 }
        if happyTicks > 0 { happyTicks -= 1 }

        if state == .walking { moveStep() }
        if state == .sleeping && tickCount % 110 == 0 { spawnZ() }

        if state == .transition {
            advanceTransition()
        } else if ticksLeft <= 0 {
            nextState()
        }
        updateImage()
    }

    private func moveStep() {
        var origin = panel.frame.origin
        origin.x += facing * Self.speed / 30.0
        let vf = visibleFrame
        if origin.x <= vf.minX { origin.x = vf.minX; facing = 1 }
        if origin.x + Self.panelW >= vf.maxX { origin.x = vf.maxX - Self.panelW; facing = -1 }
        setPanelOrigin(origin)
    }

    // MARK: 过渡动画时间轴
    /// 按「姿态 + 持续 ticks」顺序播放，结束后进入 target
    private func play(_ seq: [(String, Int)], then target: PetState) {
        let scale = tempoScale
        transSeq = seq.map { ($0.0, max(2, Int((Double($0.1) * scale).rounded()))) }
        transIdx = 0
        transLeft = transSeq.first?.1 ?? 1
        nextAfterTrans = target
        state = .transition
        ticksLeft = transSeq.reduce(0) { $0 + $1.1 }
    }

    private func advanceTransition() {
        guard !transSeq.isEmpty else { endTransition(); return }
        transLeft -= 1
        if transLeft > 0 { return }
        transIdx += 1
        if transIdx >= transSeq.count {
            endTransition()
        } else {
            transLeft = transSeq[transIdx].1
        }
    }

    private func endTransition() {
        let target = nextAfterTrans
        transSeq = []
        transIdx = 0
        switch target {
        case .walking:
            enter(.walking, for: Int.random(in: 120...300))
        case .sleeping:
            enter(.sleeping, for: Int.random(in: 300...700))
        default:
            enter(.idle, for: Int.random(in: 90...260))
        }
    }

    /// 行走 → 站定 → 转身直立 → 半蹲 → 收腿下沉（眼睛慢慢眯起） → 舔爪子 → 坐实 → 尾巴扫地两下 → 趴卧
    private var sitDownSeq: [(String, Int)] {
        var seq: [(String, Int)] = [("walk1", 5), ("quarterStand", 12),
                                    ("quarterRise", 9), ("quarterCrouch", 11)]
        if lickEnabled {
            // 舔爪子来回舔 2~3 遍：每遍是 贴爪→半抬头→抬头咽→再低头，遍与遍之间抬头歇一下
            let rounds = Int.random(in: 2...3)
            for r in 0..<rounds {
                seq += [("lickA", 7), ("lickB", 6), ("lickC", 7), ("lickD", 6)]
                if r < rounds - 1 { seq += [("lickC", 5)] }
            }
        }
        seq += [("quarterLow", 9), ("quarterSweepA_closed", 8), ("quarterSweepB_closed", 10)]
        return seq
    }

    /// 趴卧 → 几乎坐实 → 蹲起 → 半起身 → 直立（眼神警觉） → 左右张望 → 出发
    private var standUpSeq: [(String, Int)] {
        [("quarterLow", 10), ("quarterCrouch", 11), ("quarterRise", 10), ("quarterStand", 12),
         ("lookL", 13), ("lookR", 13), ("walk1", 8)]
    }

    private func nextState() {
        switch state {
        case .walking:
            play(sitDownSeq, then: .idle)
        case .idle:
            if Int.random(in: 0..<100) < 30 {
                enter(.sleeping, for: Int.random(in: 300...700))
            } else {
                play(standUpSeq, then: .walking)
            }
        case .sleeping:
            // 睡醒先伸个懒腰，再起身走
            stretchNext = .walking
            enter(.stretching, for: 44)
        case .stretching:
            if stretchNext == .idle {
                enter(.idle, for: Int.random(in: 90...180))
            } else {
                play(standUpSeq, then: .walking)
            }
        case .transition:
            endTransition()
        }
    }

    private func enter(_ s: PetState, for ticks: Int) {
        state = s
        ticksLeft = ticks
        if s == .walking { facing = Bool.random() ? 1 : -1 }
        // 发呆时偶尔开心一下
        if s == .idle && Int.random(in: 0..<100) < 40 {
            happyTicks = ticks
        }
    }

    // MARK: 渲染
    /// 缓存原始分辨率（64×64）的 CGImage：尺寸与缩放无关，绘制时才按整数倍放大
    private func image(pose: String, left: Bool) -> CGImage? {
        let key = "\(pose)-\(left ? "L" : "R")-\(paletteIndex)"
        if let img = imageCache[key] { return img }
        // 缺该表情变体时退回基础姿态（例如 stretchA_love → stretchA）
        var f = poseFrames[pose]
        if f == nil, let base = pose.split(separator: "_").first {
            f = poseFrames[String(base)]
        }
        guard let frame = f ?? poseFrames["sitA"] else { return nil }
        let draw = left ? mirrored(frame) : frame
        guard let img = makeCGImage(draw, palette: petPalettes[paletteIndex].colors) else { return nil }
        imageCache[key] = img
        return img
    }

    private func updateImage() {
        // 尾巴摆动节奏
        let wag = (tickCount / 10) % 2 == 0 ? "A" : "B"
        let pose: String
        switch state {
        case .walking:
            // 4 帧步态循环，偶尔眨一下眼
            let ph = (tickCount / 7) % 4
            pose = tickCount % 137 < 3 ? "walk\(ph)_closed" : "walk\(ph)"
        case .idle:
            if loveTicks > 0 {
                pose = "love\(wag)"               // 被摸时才是爱心眼
            } else if happyTicks > 0 {
                pose = "happy\(wag)"
            } else if tickCount % 96 < 4 {
                pose = "sleep\(wag)"              // 偶尔眨眼
            } else {
                pose = "sit\(wag)"
            }
        case .sleeping:
            pose = (tickCount / 20) % 2 == 0 ? "sleepA" : "sleepB"
        case .stretching:
            // 伸展 → 完全伸展 两帧交替，做出用力伸的感觉
            pose = (tickCount / 11) % 2 == 0 ? "stretchA" : "stretchB"
        case .transition:
            pose = transSeq.isEmpty ? "sitA" : transSeq[min(transIdx, transSeq.count - 1)].0
        }
        petView.petCG = image(pose: pose, left: facing < 0)
        petView.needsDisplay = true
    }

    // MARK: 互动
    private func pat() {
        spawnParticles(["❤️", "💗", "💕"].randomElement()!, count: Int.random(in: 1...3))
        loveTicks = 100
        switch state {
        case .walking:
            // 点一下正在走的猫：先停下来转身坐下
            play(sitDownSeq, then: .idle)
        case .sleeping:
            // 睡觉被摸醒：先伸个懒腰再发呆
            stretchNext = .idle
            enter(.stretching, for: 36)
        default:
            break
        }
    }

    private func spawnParticles(_ text: String, count: Int) {
        for i in 0..<count {
            let size = CGFloat.random(in: 14...20)
            let p = FloatParticle(text: text, fontSize: size)
            let pf = petView.frame
            let x = pf.minX + pf.width * CGFloat.random(in: 0.25...0.75)
            // 从猫头顶往上冒，窗口已预留空间，不会被裁剪
            let y = pf.maxY + 6 + CGFloat(i) * 12
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(i)) {
                p.floatUp(in: self.panel.contentView ?? self.petView, from: NSPoint(x: x, y: y))
            }
        }
    }

    private func spawnZ() {
        let size = CGFloat.random(in: 13...18)
        let p = FloatParticle(text: "Z", fontSize: size)
        let pf = petView.frame
        let x = pf.minX + pf.width * (facing < 0 ? CGFloat.random(in: 0.05...0.25)
                                                 : CGFloat.random(in: 0.75...0.95))
        p.floatUp(in: panel.contentView ?? petView, from: NSPoint(x: x, y: pf.maxY + 6))
    }

    // MARK: 右键菜单
    private func addHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // 所有菜单项的可用性由代码显式决定；关掉自动校验，
        // 避免手动 popUp 的菜单因找不到校验对象而整项变灰
        menu.autoenablesItems = false
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        // 顶部提示（新用户引导）
        addHeader("左键拖动移动 · 单击摸猫 · 右键本菜单", to: menu)
        let aboutItem = NSMenuItem(title: "关于桌面宠物 \(version)",
                                   action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        // 毛色
        addHeader("毛色", to: menu)
        for (i, p) in petPalettes.enumerated() {
            let item = NSMenuItem(title: p.name, action: #selector(changePalette(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == paletteIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 大小（百分比按实际落到的整数物理像素计算，避免出现分数像素）
        addHeader("大小", to: menu)
        let sizeNames = ["小", "中", "大"]
        for (i, name) in sizeNames.enumerated() {
            let pct = Int((devicePixel(for: i) / (Self.basePixel * backingScale) * 100).rounded())
            let item = NSMenuItem(title: "\(name) (\(pct)%)",
                                  action: #selector(changeSize(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == sizeIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 过渡节奏
        addHeader("过渡节奏", to: menu)
        let tempoNames = ["慢", "正常", "快"]
        for (i, name) in tempoNames.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(changeTempo(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = i == tempoIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // 行为
        addHeader("行为", to: menu)
        let sleepItem = NSMenuItem(title: state == .sleeping ? "唤醒" : "睡觉",
                                   action: #selector(toggleSleep), keyEquivalent: "")
        sleepItem.target = self
        menu.addItem(sleepItem)

        let pinItem = NSMenuItem(title: "固定位置（不随拖动移动）",
                                 action: #selector(togglePin), keyEquivalent: "")
        pinItem.target = self
        pinItem.state = isPinned ? .on : .off
        menu.addItem(pinItem)

        let lickItem = NSMenuItem(title: "坐下前舔爪子",
                                  action: #selector(toggleLick), keyEquivalent: "")
        lickItem.target = self
        lickItem.state = lickEnabled ? .on : .off
        menu.addItem(lickItem)

        let loginItem = NSMenuItem(title: "开机自动启动",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        loginItem.isEnabled = LoginItem.isAvailable
        menu.addItem(loginItem)

        menu.addItem(.separator())
        // 注意：target 必须显式指向 self。PetController 是 NSObject，不在响应者链里，
        // 若 target 为 nil，系统找不到响应者会直接把这一项置灰（之前「退不掉」的原因）
        let quitItem = NSMenuItem(title: "退出桌面宠物", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func changePalette(_ sender: NSMenuItem) {
        paletteIndex = sender.tag
        imageCache.removeAll()
        updateImage()
        savePrefs()
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        sizeIndex = sender.tag
        layoutPetView()
        updateImage()
        savePrefs()
    }

    @objc private func changeTempo(_ sender: NSMenuItem) {
        tempoIndex = sender.tag
        savePrefs()
    }

    @objc private func togglePin() {
        isPinned.toggle()
        petView.dragEnabled = !isPinned     // 只禁用拖动，动作照常进行
        if isPinned { spawnParticles("📌", count: 1) }
        savePrefs()
    }

    @objc private func toggleLick() {
        lickEnabled.toggle()
        savePrefs()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func quit() {
        savePrefs()
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let alert = NSAlert()
        alert.messageText = "桌面宠物 \(version)"
        alert.informativeText = """
        一只住在桌面上的像素小猫。

        左键拖动：移动位置
        单击：摸猫（爱心眼）
        右键：打开设置菜单

        版本 \(version) (\(build)) · MIT License
        """
        alert.addButton(withTitle: "好")
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleSleep() {
        if state == .sleeping {
            enter(.idle, for: 90)
        } else {
            enter(.sleeping, for: Int.random(in: 300...700))
        }
        updateImage()
    }
}

// MARK: - 应用入口
@main
struct PetApp {
    static var controller: PetController?

    /// 单实例锁：同一时刻只允许一只宠物，双击多次不会养出一窝
    private static func acquireSingleInstanceLock() -> Bool {
        let path = NSTemporaryDirectory() + "com.workbuddy.desktoppet.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }            // 拿不到锁文件就放行，不阻塞使用
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
        return true                                   // fd 故意不关闭，进程退出时内核自动释放
    }

    static func main() {
        guard acquireSingleInstanceLock() else { exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // 不占 Dock
        let c = PetController()
        controller = c
        c.start()
        app.run()
    }
}

#endif
