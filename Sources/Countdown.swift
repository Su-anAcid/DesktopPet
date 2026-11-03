import AppKit

// MARK: - 事件模型
struct CountdownEvent: Codable, Equatable {
    var id: UUID
    var title: String
    var dateKey: String      // yyyy-MM-dd；每年重复时取首次那年的日期
    var yearly: Bool

    init(id: UUID = UUID(), title: String, dateKey: String, yearly: Bool) {
        self.id = id
        self.title = title
        self.dateKey = dateKey
        self.yearly = yearly
    }
}

// MARK: - 数据
final class CountdownStore {
    static let maxCount = 20
    private(set) var events: [CountdownEvent] = []

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.countdownEvents) else {
            events = []
            return
        }
        // 解码失败就当空数组，绝不崩
        events = (try? JSONDecoder().decode([CountdownEvent].self, from: data)) ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: PrefKey.countdownEvents)
    }

    var isFull: Bool { events.count >= Self.maxCount }

    /// 同标题 + 同日期视为重复
    func contains(title: String, dateKey: String) -> Bool {
        events.contains { $0.title == title && $0.dateKey == dateKey }
    }

    /// 编辑时查重：忽略自己
    func contains(title: String, dateKey: String, excluding id: UUID) -> Bool {
        events.contains { $0.id != id && $0.title == title && $0.dateKey == dateKey }
    }

    func event(id: UUID) -> CountdownEvent? {
        events.first { $0.id == id }
    }

    @discardableResult
    func add(title: String, dateKey: String, yearly: Bool) -> Bool {
        guard !isFull, !contains(title: title, dateKey: dateKey) else { return false }
        events.append(CountdownEvent(title: title, dateKey: dateKey, yearly: yearly))
        save()
        return true
    }

    /// 原地修改；找不到 id 或与别的事件重复时返回 false
    @discardableResult
    func update(id: UUID, title: String, dateKey: String, yearly: Bool) -> Bool {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return false }
        guard !contains(title: title, dateKey: dateKey, excluding: id) else { return false }
        events[i].title = title
        events[i].dateKey = dateKey
        events[i].yearly = yearly
        save()
        return true
    }

    func remove(id: UUID) {
        events.removeAll { $0.id == id }
        save()
    }

    // MARK: 日期计算
    /// 2 月 29 日在平年落到 2 月 28 日
    private func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents()
        c.year = year
        c.month = month
        c.day = day
        guard let d = Calendar.current.date(from: c) else { return nil }
        let got = Calendar.current.dateComponents([.month, .day], from: d)
        if got.month != month || got.day != day {
            var c2 = DateComponents()
            c2.year = year
            c2.month = month
            c2.day = max(1, day - 1)
            guard let d2 = Calendar.current.date(from: c2) else { return nil }
            return Calendar.current.startOfDay(for: d2)
        }
        return Calendar.current.startOfDay(for: d)
    }

    /// 下一次发生的日期；一次性事件已过去也返回原日期（由调用方过滤）
    func nextOccurrence(_ event: CountdownEvent) -> Date? {
        guard let base = DayKey.parse(event.dateKey) else { return nil }
        guard event.yearly else { return base }

        let parts = Calendar.current.dateComponents([.month, .day], from: base)
        let m = parts.month ?? 1, d = parts.day ?? 1
        let today = DayKey.today()
        let thisYear = Calendar.current.component(.year, from: today)
        for y in [thisYear, thisYear + 1] {
            if let dt = makeDate(year: y, month: m, day: d), dt >= today { return dt }
        }
        return nil
    }

    /// 距今天数（用日历算，跨夏令时不会差一天）
    func daysLeft(to date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: DayKey.today(), to: date).day ?? 0
    }

    /// 未到期的事件，按天数升序
    func upcoming() -> [(event: CountdownEvent, date: Date, days: Int)] {
        var rows: [(CountdownEvent, Date, Int)] = []
        for e in events {
            guard let d = nextOccurrence(e) else { continue }
            let n = daysLeft(to: d)
            guard n >= 0 else { continue }        // 已过去的一次性事件不再展示（数据保留）
            rows.append((e, d, n))
        }
        return rows.sorted { a, b in
            if a.2 != b.2 { return a.2 < b.2 }
            return a.0.title < b.0.title
        }.map { (event: $0.0, date: $0.1, days: $0.2) }
    }

    /// 今天到期的事件（用于顶部提示带与一次性提醒）
    func todayEvents() -> [CountdownEvent] {
        upcoming().filter { $0.days == 0 }.map { $0.event }
    }
}

// MARK: - 行视图（滚动内容）
private final class CountdownRowsView: NSView {
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /// 点击行尾按钮时只「提出请求」；真正的编辑 / 删除由面板负责（删除要二次确认）
    var onRequestEdit: ((UUID) -> Void)?
    var onRequestDelete: ((UUID) -> Void)?

    private var rows: [(event: CountdownEvent, date: Date, days: Int)] = []
    private var hoveredIndex: Int?
    private var hoveredAction: Int?          // 0 = 编辑 / 1 = 删除

    private let rowH: CGFloat = 52
    private let sidePad: CGFloat = 20
    private let iconSize: CGFloat = 16
    private let iconStep: CGFloat = 22
    /// 给悬停时才出现的「编辑 / 删除」两个按钮留位
    private let rightReserve: CGFloat = 56

    override var isFlipped: Bool { true }

    func reload(_ rows: [(event: CountdownEvent, date: Date, days: Int)]) {
        self.rows = rows
        hoveredIndex = nil
        hoveredAction = nil
        // 调试钩子：强制显示第一行的操作图标，方便自动化截图验收
        if ProcessInfo.processInfo.environment["DESKTOPPET_DEBUG_HOVER"] == "1", !rows.isEmpty {
            hoveredIndex = 0
            hoveredAction = 0
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(rows.count, 1)) * (rowH + 1))
    }

    /// slot 0 = 编辑，slot 1 = 删除（都在行右端）
    private func actionRect(for index: Int, slot: Int) -> NSRect {
        let y = CGFloat(index) * (rowH + 1)
        let x = bounds.width - sidePad - CGFloat(2 - slot) * iconStep
        return NSRect(x: x, y: y + rowH / 2 - iconSize / 2, width: iconSize, height: iconSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let scale = ToolStyle.backingScale(self)

        for (i, row) in rows.enumerated() {
            let y = CGFloat(i) * (rowH + 1)
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: rowH)

            NSGraphicsContext.saveGraphicsState()

            // 今天到期：整行主色 8% 底
            if row.days == 0 {
                accent.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: sidePad - 6, dy: 4),
                             xRadius: 8, yRadius: 8).fill()
            }

            // 标题
            let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
            let dateFont = NSFont.systemFont(ofSize: 11)
            let titleColor: NSColor = row.days == 0 ? accent : .labelColor
            let titleRect = NSRect(x: sidePad, y: y + 9,
                                   width: bounds.width - sidePad - rightReserve - 60, height: 17)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: row.event.title, attributes: [
                .font: titleFont, .foregroundColor: titleColor, .paragraphStyle: para,
            ]).draw(in: titleRect)

            // 日期小字：完整年月日；每年重复的写的是「下一次」那天
            var dateText = DayKey.fullTitle(DayKey.key(for: row.date))
            if row.event.yearly { dateText += " · 每年" }
            NSAttributedString(string: dateText, attributes: [
                .font: dateFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: NSPoint(x: sidePad, y: y + 30))

            // 右侧天数
            let (text, color) = dayLabel(row.days)
            let numFont = ToolStyle.rounded(20, .semibold)
            let unitFont = NSFont.systemFont(ofSize: 10)
            let numStr = ToolStyle.text(text, font: numFont, color: color)
            let numSize = numStr.size()
            let unitStr = (row.days >= 2) ? ToolStyle.text(" 天", font: unitFont,
                                                           color: NSColor.secondaryLabelColor) : nil
            let unitW = unitStr?.size().width ?? 0
            let startX = bounds.width - sidePad - rightReserve - (numSize.width + unitW)
            numStr.draw(at: NSPoint(x: startX, y: y + rowH / 2 - numSize.height / 2 + 1))
            if let unitStr {
                unitStr.draw(at: NSPoint(x: startX + numSize.width + 1,
                                         y: y + rowH / 2 - numSize.height / 2 + 5))
            }

            // 悬停才出现的「编辑 / 删除」
            if hoveredIndex == i {
                let editR = actionRect(for: i, slot: 0)
                drawPencil(in: editR,
                           color: hoveredAction == 0 ? NSColor.labelColor : NSColor.tertiaryLabelColor)

                let delR = actionRect(for: i, slot: 1)
                let x = NSBezierPath()
                let inset: CGFloat = 4
                x.move(to: NSPoint(x: delR.minX + inset, y: delR.minY + inset))
                x.line(to: NSPoint(x: delR.maxX - inset, y: delR.maxY - inset))
                x.move(to: NSPoint(x: delR.maxX - inset, y: delR.minY + inset))
                x.line(to: NSPoint(x: delR.minX + inset, y: delR.maxY - inset))
                x.lineWidth = 1.2
                x.lineCapStyle = .round
                (hoveredAction == 1 ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
                x.stroke()
            }

            // 分隔线（最后一行不画）
            if i < rows.count - 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: sidePad, y: ToolStyle.px(y + rowH, scale),
                       width: bounds.width - sidePad * 2, height: 1).fill()
            }

            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func dayLabel(_ days: Int) -> (String, NSColor) {
        switch days {
        case 0: return ("今天", accent)
        case 1: return ("明天", .labelColor)
        default: return ("\(days)", .labelColor)
        }
    }

    /// 一支斜着的小铅笔
    private func drawPencil(in r: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()
        // 笔杆
        let body = NSBezierPath()
        body.move(to: NSPoint(x: r.minX + 4.5, y: r.maxY - 3.5))
        body.line(to: NSPoint(x: r.maxX - 3.5, y: r.minY + 4.5))
        body.lineWidth = 2.4
        body.lineCapStyle = .round
        body.stroke()
        // 笔尖
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: r.minX + 3.0, y: r.maxY - 3.0))
        tip.line(to: NSPoint(x: r.minX + 7.4, y: r.maxY - 3.0))
        tip.line(to: NSPoint(x: r.minX + 3.0, y: r.maxY - 7.4))
        tip.close()
        tip.fill()
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

    private func index(at p: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let i = Int(p.y / (rowH + 1))
        return (i >= 0 && i < rows.count) ? i : nil
    }

    /// 0 = 编辑 / 1 = 删除 / nil = 不在按钮上
    private func action(at p: NSPoint, in index: Int) -> Int? {
        if actionRect(for: index, slot: 0).contains(p) { return 0 }
        if actionRect(for: index, slot: 1).contains(p) { return 1 }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p)
        let act = i.flatMap { action(at: p, in: $0) }
        if i != hoveredIndex || act != hoveredAction {
            hoveredIndex = i
            hoveredAction = act
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredAction = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p), let act = action(at: p, in: i) else { return }
        let id = rows[i].event.id
        if act == 0 {
            onRequestEdit?(id)
        } else {
            onRequestDelete?(id)
        }
    }
}

// MARK: - 未来倒计时列表（含滚动与底部添加按钮）
final class CountdownListView: NSView {
    var accent: NSColor = .controlAccentColor {
        didSet {
            rowsView.accent = accent
            needsDisplay = true
        }
    }
    var onAdd: (() -> Void)?
    /// 点铅笔：面板弹出编辑框
    var onEdit: ((CountdownEvent) -> Void)?
    /// 点 ×：面板先二次确认，确认后回调 `remove(id:)`
    var onDelete: ((CountdownEvent) -> Void)?

    private let store: CountdownStore
    private let scroll = NSScrollView()
    private let rowsView = CountdownRowsView()
    private var hoveredAdd = false
    private var addRect: NSRect = .zero

    private let sidePad: CGFloat = 20

    init(store: CountdownStore) {
        self.store = store
        super.init(frame: .zero)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = rowsView
        addSubview(scroll)

        rowsView.onRequestEdit = { [weak self] id in
            guard let self, let e = self.store.event(id: id) else { return }
            self.onEdit?(e)
        }
        rowsView.onRequestDelete = { [weak self] id in
            guard let self, let e = self.store.event(id: id) else { return }
            self.onDelete?(e)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 确认删除后由面板调用
    func remove(id: UUID) {
        store.remove(id: id)
        reload()
    }

    func reload() {
        let rows = store.upcoming()
        rowsView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                height: max(CGFloat(max(rows.count, 1)) * 53, scroll.contentSize.height))
        rowsView.reload(rows)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        addRect = NSRect(x: sidePad, y: 8, width: bounds.width - sidePad * 2, height: 32)
        scroll.frame = NSRect(x: 0, y: addRect.maxY + 8,
                              width: bounds.width, height: bounds.height - addRect.maxY - 8)
        reload()
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = ToolStyle.backingScale(self)

        if store.upcoming().isEmpty {
            let str = ToolStyle.text("还没有未来倒计时", font: NSFont.systemFont(ofSize: 13),
                                     color: .secondaryLabelColor)
            let size = str.size()
            // 空态文案放在滚动区中间
            str.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                 y: scroll.frame.midY - size.height / 2))
        }

        // 添加按钮
        let full = store.isFull
        let fill = full ? NSColor.quaternaryLabelColor : accent.withAlphaComponent(0.10)
        fill.setFill()
        NSBezierPath(roundedRect: addRect, xRadius: 16, yRadius: 16).fill()

        if hoveredAdd && !full {
            accent.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: addRect, xRadius: 16, yRadius: 16).fill()
        }

        let title = full ? "最多 20 个事件" : "+ 添加事件"
        let color = full ? NSColor.tertiaryLabelColor : accent
        let str = ToolStyle.text(title, font: NSFont.systemFont(ofSize: 13, weight: .semibold), color: color)
        let size = str.size()
        str.draw(at: NSPoint(x: addRect.midX - size.width / 2, y: addRect.midY - size.height / 2))

        // 顶部细线，和内容分隔
        NSColor.separatorColor.setFill()
        NSRect(x: sidePad, y: ToolStyle.px(addRect.maxY + 4, scale),
               width: bounds.width - sidePad * 2, height: 1).fill()
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

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inAdd = addRect.contains(p)
        if inAdd != hoveredAdd {
            hoveredAdd = inAdd
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAdd = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard addRect.contains(p), !store.isFull else { return }
        onAdd?()
    }
}
