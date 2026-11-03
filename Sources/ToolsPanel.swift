import AppKit

// MARK: - 今日事件提示带
private final class TodayBandView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        accent.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let str = ToolStyle.text(text, font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                 color: accent)
        let size = str.size()
        str.draw(at: NSPoint(x: 8, y: bounds.midY - size.height / 2))
    }
}

// MARK: - 内容容器（负责 ESC 关闭）
private final class ToolsContentView: NSView {
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // ESC
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - 工具面板
final class ToolsPanelController: NSObject, NSWindowDelegate {
    enum Tab: Int {
        case checkIn = 0
        case countdown = 1
    }

    static let panelSize = NSSize(width: 320, height: 400)

    private let window: NSPanel
    private let container: ToolsContentView
    private let effect: NSVisualEffectView
    private let segmented: NSSegmentedControl
    private let band: TodayBandView
    private let calendarView: CheckInCalendarView
    private let countdownView: CountdownListView

    let checkInStore: CheckInStore
    let countdownStore: CountdownStore

    /// 主色跟随当前毛色（由 PetController 注入）
    var accentProvider: () -> NSColor = { .controlAccentColor }
    /// 打卡成功（参数是当前连续天数）
    var onCheckIn: ((Int) -> Void)?
    /// 重复打卡
    var onDuplicate: (() -> Void)?
    /// 添加 / 删除事件后（用于刷新提示带与提醒）
    var onEventsChanged: (() -> Void)?

    private var suppressAutoClose = false
    private var isShowing = false

    init(checkInStore: CheckInStore, countdownStore: CountdownStore) {
        self.checkInStore = checkInStore
        self.countdownStore = countdownStore
        self.calendarView = CheckInCalendarView(store: checkInStore)
        self.countdownView = CountdownListView(store: countdownStore)

        window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        container = ToolsContentView(frame: NSRect(origin: .zero, size: Self.panelSize))
        effect = NSVisualEffectView(frame: container.bounds)
        segmented = NSSegmentedControl(labels: ["打卡", "倒计时"],
                                       trackingMode: .selectOne, target: nil, action: nil)
        band = TodayBandView(frame: .zero)

        super.init()

        window.title = "桌面宠物工具"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false

        // 背景：毛玻璃 + 20pt 圆角
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(tabChanged(_:))
        container.addSubview(segmented)

        band.isHidden = true
        container.addSubview(band)

        container.addSubview(calendarView)
        container.addSubview(countdownView)

        container.onCancel = { [weak self] in self?.close() }
        window.contentView = container

        calendarView.onCheckIn = { [weak self] in
            guard let self else { return }
            self.onCheckIn?(self.checkInStore.stats.current)
        }
        calendarView.onDuplicate = { [weak self] in
            guard let self else { return }
            self.shake()
            self.onDuplicate?()
        }
        countdownView.onAdd = { [weak self] in self?.presentAddEvent() }
        countdownView.onDelete = { [weak self] _ in self?.eventsChanged() }
    }

    // MARK: 显示 / 关闭
    func show(tab: Tab, near catFrame: NSRect) {
        segmented.selectedSegment = tab.rawValue
        UserDefaults.standard.set(tab.rawValue, forKey: PrefKey.toolTab)

        applyAccent()
        calendarView.refresh()            // 每次打开重置到当前月并重算统计
        countdownView.reload()
        updateBand()
        applyTab(tab)
        layoutContent()

        position(near: catFrame)
        window.alphaValue = 0
        isShowing = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(container)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    func close() {
        isShowing = false
        window.orderOut(nil)
    }

    var isVisible: Bool { window.isVisible }

    /// 跨天：不重置月份，只重算今日状态与倒计时
    func refreshForNewDay() {
        calendarView.refreshDay()
        countdownView.reload()
        updateBand()
    }

    // MARK: 布局
    private func layoutContent() {
        let b = container.bounds
        let segH: CGFloat = 28
        let segW: CGFloat = 156
        segmented.frame = NSRect(x: (b.width - segW) / 2, y: b.height - 8 - segH,
                                 width: segW, height: segH)

        var top = segmented.frame.minY - 4
        if band.text.isEmpty {
            band.isHidden = true
            band.frame = .zero
        } else {
            band.isHidden = false
            band.frame = NSRect(x: 16, y: top - 24, width: b.width - 32, height: 24)
            top = band.frame.minY - 4
        }

        let content = NSRect(x: 0, y: 4, width: b.width, height: max(0, top - 4))
        calendarView.frame = content
        countdownView.frame = content
    }

    private func applyAccent() {
        let accent = accentProvider()
        calendarView.accent = accent
        countdownView.accent = accent
        band.accent = accent
    }

    private func applyTab(_ tab: Tab) {
        calendarView.isHidden = tab != .checkIn
        countdownView.isHidden = tab != .countdown
        if tab == .countdown { countdownView.reload() }
    }

    private func updateBand() {
        let titles = countdownStore.todayEvents().map { $0.title }
        if titles.isEmpty {
            band.text = ""
        } else if titles.count > 2 {
            band.text = "今天：\(titles[0]) 等 \(titles.count) 个事件"
        } else {
            band.text = "今天：" + titles.joined(separator: "、")
        }
        layoutContent()
    }

    /// 优先放猫右侧，放不下放左侧，都不行就居中，最后 clamp 进屏幕
    private func position(near catFrame: NSRect) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(catFrame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = Self.panelSize

        var x = catFrame.maxX + 12
        if x + size.width > vf.maxX {
            x = catFrame.minX - 12 - size.width
            if x < vf.minX { x = catFrame.midX - size.width / 2 }
        }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)

        var y = catFrame.maxY - size.height
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)

        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: 交互
    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let tab = Tab(rawValue: sender.selectedSegment) ?? .checkIn
        UserDefaults.standard.set(tab.rawValue, forKey: PrefKey.toolTab)
        applyTab(tab)
    }

    /// 重复打卡：面板左右轻摇一次
    private func shake() {
        let origin = window.frame.origin
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = Date().timeIntervalSince(start) / 0.25
            if p >= 1 {
                t.invalidate()
                self.window.setFrameOrigin(origin)
                return
            }
            let dx = sin(p * .pi * 4) * 6
            self.window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
        }
    }

    // MARK: 添加事件
    private func presentAddEvent() {
        guard !countdownStore.isFull else { return }

        let alert = NSAlert()
        alert.messageText = "添加倒计时事件"
        alert.informativeText = "记下一个未来的日子，猫会帮你数着。"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "例如：妈妈的生日"
        field.font = NSFont.systemFont(ofSize: 13)

        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = DayKey.today()
        picker.minDate = DayKey.today()
        picker.font = NSFont.systemFont(ofSize: 13)

        let check = NSButton(checkboxWithTitle: "每年重复", target: nil, action: nil)
        check.font = NSFont.systemFont(ofSize: 12)

        stack.addArrangedSubview(field)
        stack.addArrangedSubview(picker)
        stack.addArrangedSubview(check)
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 90)
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        suppressAutoClose = true
        defer { suppressAutoClose = false }

        field.becomeFirstResponder()

        while true {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                alert.informativeText = "标题不能为空"
                continue
            }
            guard title.count <= 30 else {
                alert.informativeText = "标题最多 30 个字"
                continue
            }
            let key = DayKey.key(for: picker.dateValue)
            guard !countdownStore.contains(title: title, dateKey: key) else {
                alert.informativeText = "这个事件已经有了"
                continue
            }

            countdownStore.add(title: title, dateKey: key, yearly: check.state == .on)
            countdownView.reload()
            updateBand()
            eventsChanged()
            return
        }
    }

    private func eventsChanged() {
        updateBand()
        onEventsChanged?()
    }

    // MARK: NSWindowDelegate
    func windowDidResignKey(_ notification: Notification) {
        guard isShowing, !suppressAutoClose else { return }
        close()
    }
}
