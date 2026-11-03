import AppKit

// MARK: - 日期键
/// 统一的「本地自然日」表示：yyyy-MM-dd。
/// 不用裸 DateFormatter —— 在泰历 / 和历等区域会写出错误年份。
enum DayKey {
    /// 调试钩子：设置 DESKTOPPET_FAKE_TODAY=2026-11-04 可覆盖「今天」
    static let fakeToday: Date? = {
        guard let raw = ProcessInfo.processInfo.environment["DESKTOPPET_FAKE_TODAY"],
              let d = parse(raw) else { return nil }
        return Calendar.current.startOfDay(for: d)
    }()

    /// 今天（零点）
    static func today() -> Date {
        if let f = fakeToday { return f }
        return Calendar.current.startOfDay(for: Date())
    }

    static func todayKey() -> String { key(for: today()) }

    static func key(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// 解析失败返回 nil（脏数据一律忽略，不崩）
    static func parse(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1970...3000).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        guard let date = Calendar.current.date(from: comps) else { return nil }
        // 2 月 30 日这类会被自动规范化，回写校验一次
        guard key(for: date) == raw else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    /// a → b 相差几天（按日历算，不做 86400 秒硬除）
    static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = parse(a), let db = parse(b) else { return nil }
        return Calendar.current.dateComponents([.day], from: da, to: db).day
    }

    static func offset(_ key: String, by days: Int) -> String? {
        guard let d = parse(key),
              let n = Calendar.current.date(byAdding: .day, value: days, to: d) else { return nil }
        return self.key(for: n)
    }

    static func monthTitle(year: Int, month: Int) -> String { "\(year) 年 \(month) 月" }

    static func dayTitle(_ key: String) -> String {
        guard let d = parse(key) else { return key }
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }
}

// MARK: - 统计
struct CheckInStats {
    let total: Int        // 累计天数（忽略未来日期）
    let best: Int         // 历史最长连续
    let current: Int      // 当前连续（今天没打但昨天打了 → 仍算连击）

    init(days: Set<String>, today: String) {
        let past = days.filter { k in
            guard let d = DayKey.daysBetween(k, today) else { return false }
            return d >= 0
        }.sorted()

        total = past.count

        // 历史最长：升序扫描，相邻差 1 天就累加
        var longest = 0
        var run = 0
        var prev: String?
        for k in past {
            if let p = prev, let diff = DayKey.daysBetween(p, k), diff == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            prev = k
        }

        func streak(from start: String) -> Int {
            var count = 0
            var cursor: String? = start
            while let c = cursor, days.contains(c) {
                count += 1
                cursor = DayKey.offset(c, by: -1)
            }
            return count
        }

        if days.contains(today) {
            current = streak(from: today)
        } else if let y = DayKey.offset(today, by: -1), days.contains(y) {
            current = streak(from: y)      // 连击未断，只是今天待打卡
        } else {
            current = 0
        }
        best = max(longest, current)
    }
}

// MARK: - 打卡数据
final class CheckInStore {
    private(set) var days: Set<String> = []

    init() { load() }

    func load() {
        let raw = UserDefaults.standard.stringArray(forKey: PrefKey.checkinDates) ?? []
        days = Set(raw.filter { DayKey.parse($0) != nil })
    }

    func save() {
        UserDefaults.standard.set(days.sorted(), forKey: PrefKey.checkinDates)
    }

    func isChecked(_ key: String) -> Bool { days.contains(key) }

    var checkedToday: Bool { days.contains(DayKey.todayKey()) }

    /// 只允许打今天；已打过返回 false（不写数据）
    @discardableResult
    func checkInToday() -> Bool {
        let today = DayKey.todayKey()
        guard !days.contains(today) else { return false }
        days.insert(today)
        save()
        return true
    }

    var stats: CheckInStats { CheckInStats(days: days, today: DayKey.todayKey()) }

    /// 某月按周一到周日排列的 42 个格子（nil = 空位，不显示邻月数字）
    func monthGrid(year: Int, month: Int) -> [String?] {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let first = Calendar.current.date(from: comps) else {
            return Array(repeating: nil, count: 42)
        }
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: first)      // 1 = 周日
        let leading = (weekday + 5) % 7                          // 周一开头
        let dayCount = cal.range(of: .day, in: .month, for: first)?.count ?? 30

        var cells: [String?] = Array(repeating: nil, count: 42)
        for d in 1...dayCount {
            let idx = leading + d - 1
            if idx < 42 {
                cells[idx] = String(format: "%04d-%02d-%02d", year, month, d)
            }
        }
        return cells
    }
}

// MARK: - 通用绘制小工具（两个工具视图共用）
enum ToolStyle {
    /// 主色：跟随当前毛色的琥珀色眼睛
    static func accent(from color: NSColor?) -> NSColor {
        color ?? NSColor.controlAccentColor
    }

    /// 主色偏亮，压在色块上的文字用深色才够对比
    static let onAccent = NSColor(srgbRed: 0.12, green: 0.09, blue: 0.06, alpha: 1)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// 对齐到物理像素，避免 1pt 描边发虚
    static func px(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    static func backingScale(_ view: NSView) -> CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 8×8 像素爪印（三个脚趾 + 一块掌垫），这是整套 UI 里唯一的像素装饰
    private static let pawArt: [String] = [
        "##.##.##",
        "##.##.##",
        "........",
        ".######.",
        ".######.",
        ".######.",
        "........",
        "........",
    ]

    static func drawPaw(in rect: NSRect, color: NSColor, scale: CGFloat) {
        let cells = pawArt.count
        let step = rect.width / CGFloat(cells)
        color.setFill()
        for (row, line) in pawArt.enumerated() {
            for (col, ch) in line.enumerated() where ch == "#" {
                let x = px(rect.minX + CGFloat(col) * step, scale)
                let y = px(rect.maxY - CGFloat(row + 1) * step, scale)
                NSRect(x: x, y: y, width: step, height: step).fill()
            }
        }
    }

    static func text(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}

// MARK: - 打卡日历视图
final class CheckInCalendarView: NSView {
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onCheckIn: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onSelectDay: ((String) -> Void)?

    private let store: CheckInStore
    private let study: StudyStore
    private var year: Int = 2026
    private var month: Int = 1
    private var selectedKey: String?
    private var hoveredKey: String?
    private var hoveredButton = false
    private var hoveredStripButton = false
    private var hoveredArrow = 0            // -1 左箭头 / 1 右箭头 / 0 无
    private var popKey: String?
    private var popScale: CGFloat = 1
    private var popTimer: Timer?
    private var studyTimer: Timer?

    // 布局常量
    private let sidePad: CGFloat = 20
    private let cell: CGFloat = 34
    private let cellGap: CGFloat = 7
    private let rowGap: CGFloat = 4
    private let headerH: CGFloat = 22
    private let weekdayH: CGFloat = 14
    private let stripH: CGFloat = 32
    private let cellRadius: CGFloat = 8

    private var cellRects: [(key: String, rect: NSRect)] = []
    private var buttonRect: NSRect = .zero
    private var prevRect: NSRect = .zero
    private var nextRect: NSRect = .zero
    private var stripRect: NSRect = .zero
    private var stripButtonRect: NSRect = .zero
    private var separatorRect: NSRect = .zero
    private var statsBlockBottom: CGFloat = 6

    init(store: CheckInStore, study: StudyStore) {
        self.store = store
        self.study = study
        super.init(frame: .zero)
        resetToCurrentMonth()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    // MARK: 状态
    func resetToCurrentMonth() {
        let today = DayKey.today()
        let c = Calendar.current.dateComponents([.year, .month], from: today)
        year = c.year ?? 2026
        month = c.month ?? 1
        selectedKey = nil
    }

    func refresh() {
        resetToCurrentMonth()
        syncStudyTimer()
        needsDisplay = true
    }

    /// 跨天时只重算，不重置用户正在看的月份
    func refreshDay() {
        syncStudyTimer()
        needsDisplay = true
    }

    /// 计时开始/暂停后，让秒数每秒刷新一次
    private func syncStudyTimer() {
        if study.isRunning, window != nil {
            guard studyTimer == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.study.isRunning, self.window?.isVisible == true else {
                    self.studyTimer?.invalidate()
                    self.studyTimer = nil
                    return
                }
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            studyTimer = t
        } else {
            studyTimer?.invalidate()
            studyTimer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncStudyTimer()
    }

    private var todayKey: String { DayKey.todayKey() }

    private func isCurrentMonth() -> Bool {
        let c = Calendar.current.dateComponents([.year, .month], from: DayKey.today())
        return year == (c.year ?? 0) && month == (c.month ?? 0)
    }

    private func shiftMonth(_ delta: Int) {
        var m = month + delta
        var y = year
        while m < 1 { m += 12; y -= 1 }
        while m > 12 { m -= 12; y += 1 }
        // 不允许翻到当前月之后
        if delta > 0 && isCurrentMonth() { return }
        year = y
        month = m
        needsDisplay = true
    }

    // MARK: 布局
    private func gridTop() -> CGFloat { bounds.height - stripH - headerH - weekdayH }

    private func layoutRects() {
        cellRects.removeAll()

        let gridW = cell * 7 + cellGap * 6
        let originX = (bounds.width - gridW) / 2
        let top = gridTop()

        for (idx, key) in store.monthGrid(year: year, month: month).enumerated() {
            guard let key else { continue }
            let r = idx / 7, c = idx % 7
            let rect = NSRect(x: originX + CGFloat(c) * (cell + cellGap),
                              y: top - CGFloat(r + 1) * cell - CGFloat(r) * rowGap,
                              width: cell, height: cell)
            cellRects.append((key, rect))
        }

        // 顶部「今日学习」条
        stripRect = NSRect(x: sidePad, y: bounds.height - stripH + 2,
                           width: bounds.width - sidePad * 2, height: stripH - 4)
        stripButtonRect = NSRect(x: stripRect.maxX - 10 - 64, y: stripRect.midY - 11,
                                 width: 64, height: 22)

        // 月份左右箭头
        let titleY = bounds.height - stripH - headerH
        prevRect = NSRect(x: sidePad, y: titleY, width: 24, height: headerH)
        nextRect = NSRect(x: bounds.width - sidePad - 24, y: titleY, width: 24, height: headerH)

        // 底部统计块：锚定在分隔线与视图底边之间，放不下时向底边贴齐
        let scale = ToolStyle.backingScale(self)
        let gridBottom = gridTop() - 6 * cell - 5 * rowGap
        let separatorY = ToolStyle.px(gridBottom - 8, scale)
        separatorRect = NSRect(x: sidePad, y: separatorY, width: bounds.width - sidePad * 2, height: 1)

        let blockH: CGFloat = 62
        let regionBottom: CGFloat = 4
        let regionTop = separatorY - 6
        statsBlockBottom = regionBottom + max(0, (regionTop - regionBottom - blockH) / 2)

        // 打卡按钮（右上，与连续天数同一行；第二行留给文字，避免压住按钮）
        buttonRect = NSRect(x: bounds.width - sidePad - 96,
                            y: statsBlockBottom + 24,
                            width: 96, height: 32)
    }

    // MARK: 绘制
    override func draw(_ dirtyRect: NSRect) {
        layoutRects()
        let scale = ToolStyle.backingScale(self)
        drawStudyStrip(scale: scale)
        drawMonthHeader(scale: scale)
        drawWeekdayRow(scale: scale)
        drawCells(scale: scale)
        drawStats(scale: scale)
    }

    /// 顶部学习计时条：今日累计时长 + 开始/暂停
    private func drawStudyStrip(scale: CGFloat) {
        accent.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: stripRect, xRadius: 10, yRadius: 10).fill()

        let running = study.isRunning
        let label = ToolStyle.text("今日学习", font: NSFont.systemFont(ofSize: 11),
                                   color: .secondaryLabelColor)
        let labelSize = label.size()
        label.draw(at: NSPoint(x: stripRect.minX + 12, y: stripRect.midY - labelSize.height / 2))

        let value = ToolStyle.text(StudyStore.format(study.todaySeconds),
                                   font: ToolStyle.rounded(12, .semibold),
                                   color: running ? accent : .labelColor)
        let valueSize = value.size()
        value.draw(at: NSPoint(x: stripRect.minX + 12 + labelSize.width + 6,
                               y: stripRect.midY - valueSize.height / 2))

        // 计时中的小圆点（呼吸闪烁）
        if running {
            let on = Int(Date().timeIntervalSince1970) % 2 == 0
            accent.withAlphaComponent(on ? 0.9 : 0.3).setFill()
            let d: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: stripRect.minX + 12 + labelSize.width + 6 + valueSize.width + 7,
                                        y: stripRect.midY - d / 2, width: d, height: d)).fill()
        }

        // 色阶图例：五个小方块对应 30 分内 → 4 小时以上
        let legendSize: CGFloat = 7
        let legendGap: CGFloat = 3
        let legendW = CGFloat(5) * legendSize + 4 * legendGap
        let legendX = stripButtonRect.minX - 12 - legendW
        for i in 1...5 {
            let r = NSRect(x: legendX + CGFloat(i - 1) * (legendSize + legendGap),
                           y: stripRect.midY - legendSize / 2,
                           width: legendSize, height: legendSize)
            StudyTier.fill(i, accent: accent).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }

        // 右侧按钮
        if running {
            accent.withAlphaComponent(hoveredStripButton ? 0.26 : 0.18).setFill()
        } else {
            accent.withAlphaComponent(hoveredStripButton ? 0.85 : 1.0).setFill()
        }
        NSBezierPath(roundedRect: stripButtonRect, xRadius: 11, yRadius: 11).fill()

        let title = running ? "暂停" : "开始"
        let str = ToolStyle.text(title, font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                 color: running ? accent : ToolStyle.onAccent)
        let size = str.size()
        str.draw(at: NSPoint(x: stripButtonRect.midX - size.width / 2,
                             y: stripButtonRect.midY - size.height / 2))
    }

    private func drawMonthHeader(scale: CGFloat) {
        let titleY = bounds.height - stripH - headerH
        let title = DayKey.monthTitle(year: year, month: month)
        let font = ToolStyle.rounded(13, .semibold)
        let str = ToolStyle.text(title, font: font, color: .labelColor)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: titleY + (headerH - size.height) / 2))

        // 左右箭头：用 bezier 画，避免字形基线不稳
        func chevron(center: NSPoint, left: Bool, color: NSColor) {
            let p = NSBezierPath()
            let dx: CGFloat = left ? -3.5 : 3.5     // 左箭头尖朝左，右箭头尖朝右
            p.move(to: NSPoint(x: center.x - dx, y: center.y + 4.5))
            p.line(to: NSPoint(x: center.x + dx, y: center.y))
            p.line(to: NSPoint(x: center.x - dx, y: center.y - 4.5))
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            color.setStroke()
            p.stroke()
        }

        let enabledNext = !isCurrentMonth()
        chevron(center: NSPoint(x: prevRect.midX, y: prevRect.midY), left: true,
                color: hoveredArrow == -1 ? .labelColor : .secondaryLabelColor)
        chevron(center: NSPoint(x: nextRect.midX, y: nextRect.midY), left: false,
                color: enabledNext ? (hoveredArrow == 1 ? .labelColor : .secondaryLabelColor)
                                   : .quaternaryLabelColor)
    }

    private func drawWeekdayRow(scale: CGFloat) {
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        let font = NSFont.systemFont(ofSize: 11)
        let gridW = cell * 7 + cellGap * 6
        let originX = (bounds.width - gridW) / 2
        let y = gridTop() + 2
        for (i, n) in names.enumerated() {
            let str = ToolStyle.text(n, font: font, color: .tertiaryLabelColor)
            let w = str.size().width
            let x = originX + CGFloat(i) * (cell + cellGap) + (cell - w) / 2
            str.draw(at: NSPoint(x: x, y: y))
        }
    }

    private func drawCells(scale: CGFloat) {
        let today = todayKey
        let cal = Calendar.current
        let todayStart = DayKey.today()

        for (key, rect) in cellRects {
            let square = NSRect(x: rect.minX + 2, y: rect.minY + 2, width: 30, height: 30)
            var isFuture = false
            if let d = DayKey.parse(key) {
                isFuture = d > todayStart
            }
            let checked = store.isChecked(key)
            let isToday = key == today
            // 学习时长决定格子颜色：学得越久，颜色越深
            let minutes = study.minutes(for: key)
            let tier = StudyTier.level(minutes: minutes)

            // hover 高亮（底部圆角底）
            if hoveredKey == key && !isFuture {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: cellRadius, yRadius: cellRadius).fill()
            }

            // 选中：细描边
            if selectedKey == key {
                NSColor.tertiaryLabelColor.setStroke()
                let p = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                     xRadius: cellRadius + 1, yRadius: cellRadius + 1)
                p.lineWidth = 1
                p.stroke()
            }

            var numberColor: NSColor = .labelColor
            var alpha: CGFloat = 1

            if checked {
                // 已打卡：实心块，颜色按当天学习时长走色阶
                // （新打卡的格子有一次 0.2s 缩放入场）
                let s: CGFloat = (popKey == key) ? popScale : 1
                let w = square.width * s
                let scaled = NSRect(x: square.midX - w / 2, y: square.midY - w / 2, width: w, height: w)
                StudyTier.fill(tier, accent: accent).setFill()
                NSBezierPath(roundedRect: scaled, xRadius: cellRadius * s, yRadius: cellRadius * s).fill()
                numberColor = StudyTier.onFill(tier)
            } else if isToday {
                // 今天未打卡：主色描边 + 主色数字
                let p = NSBezierPath(roundedRect: square.insetBy(dx: 0.75, dy: 0.75),
                                     xRadius: cellRadius, yRadius: cellRadius)
                p.lineWidth = 1.5
                accent.setStroke()
                p.stroke()
                numberColor = accent
                if tier > 0 {
                    // 学过但忘了打卡：淡一层色阶打个底
                    StudyTier.fill(tier, accent: accent).withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: square, xRadius: cellRadius, yRadius: cellRadius).fill()
                    numberColor = accent
                }
            } else if isFuture {
                alpha = 0.3
            } else if tier > 0 {
                // 过去某天有计时但没打卡
                StudyTier.fill(tier, accent: accent).withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: square, xRadius: cellRadius, yRadius: cellRadius).fill()
                numberColor = StudyTier.text(tier)
            }

            let day = cal.component(.day, from: DayKey.parse(key) ?? Date())
            // 有学习记录的格子：数字上移，底部补一行时长（45m / 2h）
            let hasStudy = minutes > 0
            let font = NSFont.systemFont(ofSize: hasStudy ? 12 : 13,
                                         weight: checked || isToday ? .semibold : .regular)
            let str = ToolStyle.text("\(day)", font: font, color: numberColor.withAlphaComponent(alpha))
            let size = str.size()
            let numY = hasStudy ? rect.midY + 4 - size.height / 2 : rect.midY - size.height / 2
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: numY))

            if hasStudy {
                let timeColor: NSColor
                if checked {
                    timeColor = StudyTier.onFill(tier).withAlphaComponent(0.78)
                } else if isToday {
                    timeColor = accent.withAlphaComponent(0.85)
                } else {
                    timeColor = StudyTier.text(tier)
                }
                let t = ToolStyle.text(StudyStore.compact(minutes: minutes),
                                       font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
                                       color: timeColor.withAlphaComponent(alpha))
                let ts = t.size()
                t.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.minY + 4))
            }
        }
    }

    private func drawStats(scale: CGFloat) {
        let stats = store.stats

        // 1pt 分隔线
        NSColor.separatorColor.setFill()
        separatorRect.fill()

        // 右侧按钮先画，第二行文字在它下方，不会互相压住
        let checked = store.checkedToday
        let fill = checked ? accent.withAlphaComponent(0.28) : accent
        fill.setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 16, yRadius: 16).fill()

        if hoveredButton && !checked {
            NSColor.black.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: buttonRect, xRadius: 16, yRadius: 16).fill()
        }

        // 左侧：连续天数
        let numFont = ToolStyle.rounded(28, .semibold)
        let unitFont = NSFont.systemFont(ofSize: 12)
        let num = ToolStyle.text("\(stats.current)", font: numFont, color: .labelColor)
        let unit = ToolStyle.text(" 天", font: unitFont, color: .secondaryLabelColor)
        let numSize = num.size()
        let numY = statsBlockBottom + 22
        num.draw(at: NSPoint(x: sidePad, y: numY))
        unit.draw(at: NSPoint(x: sidePad + numSize.width + 2, y: numY + 4))

        // 第二行：选中日期优先（带上当天学习时长），否则显示最长/累计 + 累计学习
        let subFont = NSFont.systemFont(ofSize: 11)
        let subText: String
        if let sel = selectedKey {
            let state = store.isChecked(sel) ? "已打卡" : (sel == todayKey ? "今天 · 未打卡" : "未打卡")
            let studied = study.seconds(for: sel)
            subText = studied >= 60
                ? "\(DayKey.dayTitle(sel)) · \(state) · 学习 \(StudyStore.format(studied))"
                : "\(DayKey.dayTitle(sel)) · \(state)"
        } else {
            var text = "最长 \(stats.best) 天 · 累计 \(stats.total) 天"
            let total = study.totalSeconds
            if total >= 60 { text += " · 共学习 \(StudyStore.format(total))" }
            subText = text
        }
        ToolStyle.text(subText, font: subFont, color: .secondaryLabelColor)
            .draw(at: NSPoint(x: sidePad, y: statsBlockBottom + 4))

        // 按钮文字
        let title = checked ? "已打卡 ✓" : "今天打卡"
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let color = checked ? NSColor.secondaryLabelColor : ToolStyle.onAccent
        let str = ToolStyle.text(title, font: font, color: color)
        let size = str.size()
        let pawSize: CGFloat = 8
        let gap: CGFloat = 6
        let totalW = pawSize + gap + size.width
        let startX = buttonRect.midX - totalW / 2
        ToolStyle.drawPaw(in: NSRect(x: startX, y: buttonRect.midY - pawSize / 2,
                                     width: pawSize, height: pawSize),
                          color: color, scale: scale)
        str.draw(at: NSPoint(x: startX + pawSize + gap, y: buttonRect.midY - size.height / 2))
    }

    // MARK: 交互
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func key(at point: NSPoint) -> String? {
        cellRects.first { $0.rect.contains(point) }?.key
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let k = key(at: p)
        let inButton = buttonRect.contains(p)
        let inStrip = stripButtonRect.contains(p)
        let arrow: Int = prevRect.contains(p) ? -1 : (nextRect.contains(p) ? 1 : 0)
        if k != hoveredKey || inButton != hoveredButton || arrow != hoveredArrow
            || inStrip != hoveredStripButton {
            hoveredKey = k
            hoveredButton = inButton
            hoveredStripButton = inStrip
            hoveredArrow = arrow
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredKey = nil
        hoveredButton = false
        hoveredStripButton = false
        hoveredArrow = 0
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 学习计时开关
        if stripButtonRect.contains(p) {
            study.toggle()
            syncStudyTimer()
            needsDisplay = true
            return
        }

        if buttonRect.contains(p) {
            guard !store.checkedToday else { return }
            if store.checkInToday() {
                let today = todayKey
                popKey = today
                animatePop()
                needsDisplay = true
                onCheckIn?()
            } else {
                onDuplicate?()
            }
            return
        }

        if prevRect.contains(p) { shiftMonth(-1); return }
        if nextRect.contains(p) {
            if !isCurrentMonth() { shiftMonth(1) }
            return
        }

        guard let k = key(at: p), let d = DayKey.parse(k), d <= DayKey.today() else { return }
        selectedKey = (selectedKey == k) ? nil : k
        needsDisplay = true
        onSelectDay?(k)
    }

    private func animatePop() {
        popTimer?.invalidate()
        popScale = 0.6
        let start = Date()
        popTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let progress = min(1, Date().timeIntervalSince(start) / 0.2)
            // 轻微回弹
            let overshoot = 1 + 0.12 * sin(progress * .pi)
            self.popScale = 0.6 + (overshoot - 0.6) * progress
            self.needsDisplay = true
            if progress >= 1 {
                t.invalidate()
                self.popKey = nil
                self.popScale = 1
                self.needsDisplay = true
            }
        }
    }
}
