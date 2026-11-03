#if !PREVIEW
import AppKit

// MARK: - 宠物视图
final class PetView: NSView {
    var petCG: CGImage?
    var artPixel: CGFloat = 5        // 每个艺术像素占多少 pt（×backingScale 必为整数）
    var dragEnabled = true          // 固定位置时关闭拖动
    var onPat: (() -> Void)?
    var onDragEnd: (() -> Void)?
    /// 右键：直接打开小工具面板（毛色 / 大小 / 行为 / 退出都在菜单栏猫头图标里）
    var onRightClick: (() -> Void)?

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
        onRightClick?()
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
    // 小工具
    static let checkinDates = "checkinDates"
    static let countdownEvents = "countdownEvents"
    static let toolTab = "toolTab"
    static let countdownBubbleDay = "countdownBubbleDay"
    static let studySeconds = "studySeconds"
    // 提醒设置
    static let cdRemindEnabled = "cdRemindEnabled"
    static let cdRemindLead = "cdRemindLead"
    static let cdRemindInterval = "cdRemindInterval"
    static let cdRemindLastAt = "cdRemindLastAt"
    static let studyRemindEnabled = "studyRemindEnabled"
    static let studyRemindInterval = "studyRemindInterval"
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
    private var statusItem: NSStatusItem?
    private var isPetHidden = false

    // 小工具：打卡日历 + 未来倒计时 + 打卡计时
    let checkInStore = CheckInStore()
    let countdownStore = CountdownStore()
    let studyStore = StudyStore()
    let reminderSettings = ReminderSettings()
    private var toolsPanel: ToolsPanelController?
    private var cachedDayKey = DayKey.todayKey()
    private var lastBubbleDay = UserDefaults.standard.string(forKey: PrefKey.countdownBubbleDay) ?? ""
    /// 上次倒计时播报的时间点：分钟级间隔靠它判断（跨重启也保留，避免重新开就轰炸）
    private var lastBubbleAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: PrefKey.cdRemindLastAt)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let d = newValue {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: PrefKey.cdRemindLastAt)
            } else {
                UserDefaults.standard.removeObject(forKey: PrefKey.cdRemindLastAt)
            }
        }
    }
    private var countdownBubble: PetBubble?
    /// 上一次「学习时长」播报时的今日累计秒数（用于按间隔触发）
    private var studyAnnounceBase = 0
    private var studyWasRunning = false

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
        reminderSettings.onChange = { [weak self] in self?.reminderSettingsChanged() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.studyStore.pause()     // 结算最后一段学习时间并落盘
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
        petView.onRightClick = { [weak self] in self?.toggleToolsPanel() }
    }

    func start() {
        setupStatusItem()
        lastBackingScale = backingScale
        if let o = savedOrigin, isOriginUsable(o) {
            setPanelOrigin(o)
            panel.makeKeyAndOrderFront(nil)
        } else {
            positionAtBottomRight()
        }
        layoutPetView()
        updateImage()

        // 调试钩子：DESKTOPPET_OPEN_TOOLS=checkin|countdown|settings 启动后直接打开面板，方便自测
        if let raw = ProcessInfo.processInfo.environment["DESKTOPPET_OPEN_TOOLS"] {
            let tab: ToolsPanelController.Tab
            switch raw {
            case "countdown": tab = .countdown
            case "settings": tab = .settings
            default: tab = .checkIn
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let c = self.toolsPanel ?? self.makeToolsPanel()
                self.toolsPanel = c
                c.show(tab: tab, near: self.panel.frame)
            }
        }

        // 开机先让猫说句话：报一下最近的那个日子（每天最多一次）
        // DESKTOPPET_SHOW_BUBBLE=1 可强制立即说话，方便自测
        let forceBubble = ProcessInfo.processInfo.environment["DESKTOPPET_SHOW_BUBBLE"] != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (forceBubble ? 1.0 : 3.0)) { [weak self] in
            self?.maybeShowCountdownBubble(force: forceBubble)
        }

        // 调试钩子：DESKTOPPET_SHOW_ABOUT=1 直接弹「关于」，方便检查文案排版
        if ProcessInfo.processInfo.environment["DESKTOPPET_SHOW_ABOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showAbout()
            }
        }

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

        // 打卡计时：主循环驱动，休眠/卡顿后的时间跳变会被 tick 内部削掉
        if studyStore.isRunning && !studyWasRunning {
            // 开始（或从暂停恢复）：按当前进度对齐到间隔网格，避免一恢复就立刻播报
            let step = max(60, reminderSettings.studyIntervalMinutes * 60)
            studyAnnounceBase = (studyStore.todaySeconds / step) * step
        }
        studyWasRunning = studyStore.isRunning
        studyStore.tick()

        if state == .transition {
            advanceTransition()
        } else if ticksLeft <= 0 {
            nextState()
        }

        // 每 30 帧（约 1 秒）检查一次跨天与今日事件提醒
        if tickCount % 30 == 0 {
            refreshDayIfNeeded()
            maybeShowCountdownBubble(force: false)
            maybeShowStudyBubble()
        }

        // 猫在散步时气泡跟着走（10Hz 足够，不必每帧挪窗口）
        if tickCount % 3 == 0, countdownBubble?.isVisible == true {
            countdownBubble?.reposition(near: catRectOnScreen())
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

    // MARK: 菜单栏图标
    /// 菜单栏常驻入口：猫被拖到角落、或窗口意外不在前台时，还能找到它并退出
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = StatusIcon.make()
            button.toolTip = "桌面宠物"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self          // 每次展开前重建，保证勾选状态是最新的
        item.menu = menu
        statusItem = item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let show = NSMenuItem(title: isPetHidden ? "显示猫咪" : "隐藏猫咪",
                              action: #selector(togglePetVisible), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let home = NSMenuItem(title: "回到桌面右下角", action: #selector(movePetHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)

        let statusCheckIn = NSMenuItem(title: "打卡日历…", action: #selector(openTools(_:)), keyEquivalent: "")
        statusCheckIn.tag = ToolsPanelController.Tab.checkIn.rawValue
        statusCheckIn.target = self
        menu.addItem(statusCheckIn)

        let statusCountdown = NSMenuItem(title: "未来倒计时…", action: #selector(openTools(_:)), keyEquivalent: "")
        statusCountdown.tag = ToolsPanelController.Tab.countdown.rawValue
        statusCountdown.target = self
        menu.addItem(statusCountdown)

        let statusBubble = NSMenuItem(title: "提醒一下未来倒计时", action: #selector(showCountdownBubbleNow), keyEquivalent: "")
        statusBubble.target = self
        statusBubble.isEnabled = !countdownStore.upcoming().isEmpty
        menu.addItem(statusBubble)

        let statusSettings = NSMenuItem(title: "提醒设置…", action: #selector(openTools(_:)), keyEquivalent: "")
        statusSettings.tag = ToolsPanelController.Tab.settings.rawValue
        statusSettings.target = self
        menu.addItem(statusSettings)

        menu.addItem(.separator())

        let sleep = NSMenuItem(title: state == .sleeping ? "唤醒猫咪" : "让猫咪睡觉",
                               action: #selector(toggleSleep), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)

        let pin = NSMenuItem(title: "固定位置", action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        pin.state = isPinned ? .on : .off
        menu.addItem(pin)

        let lick = NSMenuItem(title: "坐下前舔爪子", action: #selector(toggleLick), keyEquivalent: "")
        lick.target = self
        lick.state = lickEnabled ? .on : .off
        menu.addItem(lick)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        login.isEnabled = LoginItem.isAvailable
        menu.addItem(login)
        menu.addItem(.separator())

        // 毛色 / 大小 / 节奏收进子菜单，托盘菜单保持短
        let look = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let lookMenu = NSMenu()
        lookMenu.autoenablesItems = false
        for (i, p) in petPalettes.enumerated() {
            let it = NSMenuItem(title: p.name, action: #selector(changePalette(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == paletteIndex ? .on : .off
            lookMenu.addItem(it)
        }
        lookMenu.addItem(.separator())
        for (i, name) in ["小", "中", "大"].enumerated() {
            let it = NSMenuItem(title: "大小：\(name)", action: #selector(changeSize(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == sizeIndex ? .on : .off
            lookMenu.addItem(it)
        }
        lookMenu.addItem(.separator())
        for (i, name) in ["慢", "正常", "快"].enumerated() {
            let it = NSMenuItem(title: "节奏：\(name)", action: #selector(changeTempo(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == tempoIndex ? .on : .off
            lookMenu.addItem(it)
        }
        look.submenu = lookMenu
        menu.addItem(look)
        menu.addItem(.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "关于桌面宠物 \(version)", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出桌面宠物", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePetVisible() {
        isPetHidden.toggle()
        if isPetHidden {
            countdownBubble?.dismiss()
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func movePetHome() {
        positionAtBottomRight()
        if isPetHidden {
            isPetHidden = false
            panel.makeKeyAndOrderFront(nil)
        }
        savePrefs()
    }

    // MARK: 小工具（打卡日历 / 事件倒计时 / 提醒设置）
    private func makeToolsPanel() -> ToolsPanelController {
        let c = ToolsPanelController(checkInStore: checkInStore,
                                     countdownStore: countdownStore,
                                     studyStore: studyStore,
                                     settings: reminderSettings)
        c.accentProvider = { [weak self] in
            guard let self else { return .controlAccentColor }
            return ToolStyle.accent(from: petPalettes[self.paletteIndex].colors["g"])
        }
        c.onCheckIn = { [weak self] streak in
            guard let self else { return }
            self.cheer(ticks: 90, particle: "❤", count: 4)
            // 里程碑额外报一次
            if [1, 3, 7, 14, 21, 30, 50, 100, 200, 365].contains(streak) {
                self.spawnParticles("连续 \(streak) 天！", count: 1)
            }
            // 打卡时把「今天打了多久」一起说出来（跟着打卡提醒的开关走）
            let studied = self.studyStore.todaySeconds
            if self.reminderSettings.studyEnabled, studied >= 60 {
                self.presentBubble(title: "今日打卡",
                                   message: "今天已经打卡 \(StudyStore.format(studied)) 了",
                                   hint: "连续 \(streak) 天 · 点我看看日历",
                                   tab: .checkIn)
            }
        }
        c.onDuplicate = { [weak self] in
            self?.spawnParticles("今天已经打过卡啦", count: 1)
        }
        c.onEventsChanged = { [weak self] in
            // 刚记下一个日子，让猫立刻念一遍
            self?.maybeShowCountdownBubble(force: true)
        }
        return c
    }

    private func openToolsPanel(tab: ToolsPanelController.Tab) {
        let controller = toolsPanel ?? makeToolsPanel()
        toolsPanel = controller
        controller.show(tab: tab, near: panel.frame)
    }

    @objc private func openTools(_ sender: NSMenuItem) {
        openToolsPanel(tab: ToolsPanelController.Tab(rawValue: sender.tag) ?? .checkIn)
    }

    @objc private func showCountdownBubbleNow() {
        maybeShowCountdownBubble(force: true)
    }

    /// 工具面板的情绪反馈入口：只叠加爱心与粒子，不打断当前动作
    func cheer(ticks: Int = 90, particle: String? = nil, count: Int = 1) {
        loveTicks = max(loveTicks, ticks)
        // 唯一例外：睡觉时先温柔唤醒
        if state == .sleeping { enter(.idle, for: 120) }
        if let particle { spawnParticles(particle, count: count) }
    }

    /// 跨天检测：猫可能连续开机好几天，不能把「今天」缓存成常量
    private func refreshDayIfNeeded() {
        let key = DayKey.todayKey()
        guard key != cachedDayKey else { return }
        cachedDayKey = key
        checkInStore.load()
        countdownStore.load()
        toolsPanel?.refreshForNewDay()
    }

    // MARK: 倒计时气泡
    /// 猫在屏幕上的矩形（取猫的绘制区域，不含窗口上下留给粒子的空白）
    private func catRectOnScreen() -> NSRect {
        let pf = panel.frame
        let pv = petView.frame
        return NSRect(x: pf.minX + pv.minX, y: pf.minY + pv.minY,
                      width: pv.width, height: pv.height)
    }

    /// 让猫张嘴说一句倒计时。是否开启、提前范围、提醒间隔都在「提醒」设置页里。
    /// force = 用户手动点 / 刚添加了事件（跳过所有节奏限制，但仍然是用户主动要的）
    private func maybeShowCountdownBubble(force: Bool) {
        guard force || reminderSettings.countdownEnabled else { return }
        let rows = countdownStore.upcoming()
        guard let first = rows.first else { return }

        // 提前范围：事件还没进入「开始提醒」的窗口就完全不打扰
        if !force && !reminderSettings.isInRange(days: first.days) { return }

        let today = DayKey.todayKey()
        if !force {
            if first.days == 0 {
                // 事件当天：一天只喊一次，免得「就是今天」每分钟重复
                guard lastBubbleDay != today else { return }
            } else {
                // 其余日子按分钟级间隔走（可设 30 分钟 / 1 小时 / 每天…）
                guard reminderSettings.countdownIntervalElapsed(since: lastBubbleAt) else { return }
            }
        }
        lastBubbleDay = today
        lastBubbleAt = Date()
        UserDefaults.standard.set(today, forKey: PrefKey.countdownBubbleDay)

        let message: String
        switch first.days {
        case 0: message = "「\(first.event.title)」就是今天！"
        case 1: message = "「\(first.event.title)」就是明天"
        default: message = "距离「\(first.event.title)」还有 \(first.days) 天"
        }
        let hint = rows.count > 1 ? "点我看看另外 \(rows.count - 1) 个日子" : "点我打开未来倒计时"

        presentBubble(title: "未来倒计时提醒", message: message, hint: hint, tab: .countdown)
    }

    /// 学习计时中按间隔播报「已经学了多久」
    private func maybeShowStudyBubble() {
        guard reminderSettings.studyEnabled, studyStore.isRunning else { return }
        let step = max(60, reminderSettings.studyIntervalMinutes * 60)
        let now = studyStore.todaySeconds
        // 跨天或数据被清零：重新按间隔网格对齐，避免一直不播报
        if now < studyAnnounceBase { studyAnnounceBase = (now / step) * step }
        guard now - studyAnnounceBase >= step else { return }
        guard countdownBubble?.isVisible != true else { return }   // 让正在说话的气泡先说完
        studyAnnounceBase = now

        let message = now >= 3600
            ? "已经打卡 \(StudyStore.format(now)) 了，起来走两步？"
            : "已经打卡 \(StudyStore.format(now)) 啦，再接再厉"
        presentBubble(title: "打卡计时", message: message,
                      hint: "点我打开打卡日历", tab: .checkIn)
    }

    /// 统一的「猫说话」入口：同一个气泡窗口复用，点一下跳到对应面板
    private func presentBubble(title: String, message: String, hint: String,
                               tab: ToolsPanelController.Tab) {
        let bubble: PetBubble
        if let existing = countdownBubble {
            bubble = existing
        } else {
            let fresh = PetBubble()
            countdownBubble = fresh
            bubble = fresh
        }
        bubble.onClick = { [weak self] in self?.openToolsPanel(tab: tab) }
        bubble.show(title: title,
                    message: message,
                    hint: hint,
                    accent: ToolStyle.accent(from: petPalettes[paletteIndex].colors["g"]),
                    near: catRectOnScreen())
    }

    /// 设置项改动后：重置播报节奏，并把设置页刷成最新的
    private func reminderSettingsChanged() {
        let step = max(60, reminderSettings.studyIntervalMinutes * 60)
        studyAnnounceBase = (studyStore.todaySeconds / step) * step
        toolsPanel?.refreshSettings()
        // 刚打开倒计时提醒且今天还没说过 → 立刻给个反馈
        if reminderSettings.countdownEnabled { maybeShowCountdownBubble(force: false) }
    }

    // MARK: 右键 → 小工具面板
    /// 右键点猫直接开面板（再点一次收起），回到上次看的 tab。
    /// 毛色 / 大小 / 节奏 / 行为 / 退出都不在这儿，统一放在菜单栏猫头图标里。
    private func toggleToolsPanel() {
        if let c = toolsPanel {
            if c.isVisible {
                c.close()
                return
            }
            // 点猫的瞬间面板会因为失焦自动关掉，这种情况下别又把它拉起来
            if let t = c.lastClosedAt, Date().timeIntervalSince(t) < 0.4 { return }
        }
        let saved = UserDefaults.standard.object(forKey: PrefKey.toolTab) as? Int
        let tab = ToolsPanelController.Tab(rawValue: saved ?? 0) ?? .checkIn
        openToolsPanel(tab: tab)
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
        一只住在桌面上的像素小猫。它自己散步、发呆、睡觉，顺便帮你记着日子。

        【鼠标操作】
        • 左键拖动：把猫挪到别处（「固定位置」开启后不可拖动）
        • 单击：摸猫，冒爱心眼和 ❤️
        • 右键：打开或收起小工具面板（回到上次看的标签页）

        【小工具面板】面板顶部切换三个标签
        • 打卡：每天点一次「今天打卡」，猫会开心，月历留痕并统计连续天数；顶部「开始 / 暂停」记录打卡时长，日历格子按时长深浅着色
        • 未来倒计时：记下生日、上线、考试等日子（列表里显示完整年月日），支持每年重复，按剩余天数排序；鼠标移到某一行，右侧出现铅笔（编辑）和 ×（删除，会先确认一次）
        • 提醒：未来倒计时播报开关、开始提醒的范围（不限制 / 提前 30 天 / 提前 7 天 / 仅当天）、提醒间隔（30 分钟 / 1 小时 / 每天 / 每 3 天或自定义）；打卡计时中每过 5 / 10 / 15 / 30 分钟或自定义间隔，猫会冒气泡播报「已经打卡了多久」

        【其余设置】点菜单栏的猫头图标
        显示 / 隐藏猫咪、回到桌面右下角、打卡日历 / 未来倒计时 / 提醒一下未来倒计时 / 提醒设置、睡觉 / 唤醒、固定位置、坐下前舔爪子、开机自动启动、外观（毛色 / 大小 / 过渡节奏）、关于、退出

        所有数据只存在本机（UserDefaults），不上传。

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

// MARK: - 菜单栏菜单刷新
extension PetController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        let fresh = makeStatusMenu()
        let items = fresh.items
        menu.removeAllItems()
        for item in items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}

// MARK: - 菜单栏图标（16×16 像素猫头，模板图自适应深浅色菜单栏）
enum StatusIcon {
    private static let art: [String] = [
        "................",
        "....##....##....",
        "...####..####...",
        "..############..",
        "..############..",
        ".##############.",
        ".###..####..###.",
        ".###..####..###.",
        ".##############.",
        ".##############.",
        "..############..",
        "..############..",
        "...##########...",
        "....########....",
        "................",
        "................",
    ]

    static func make() -> NSImage {
        let cells = art.count
        let side: CGFloat = 16
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            let step = side / CGFloat(cells)
            for (row, line) in art.enumerated() {
                for (col, ch) in line.enumerated() where ch == "#" {
                    let r = CGRect(x: CGFloat(col) * step,
                                   y: side - CGFloat(row + 1) * step,
                                   width: step, height: step)
                    r.fill()
                }
            }
            return true
        }
        img.isTemplate = true      // 让菜单栏按明暗自动反色
        return img
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
