import AppKit

// MARK: - 提醒设置
/// 两种「猫主动说话」的提醒：倒计时播报、学习时长播报。
/// 设置直接落 UserDefaults，改完立即生效（面板里能马上看到效果）。
final class ReminderSettings {
    // MARK: 选项
    /// 事件进入多少天内才开始播报；nil = 不限制
    enum CountdownLead: Int, CaseIterable {
        case unlimited = 0
        case thirtyDays = 1
        case sevenDays = 2
        case sameDay = 3

        var title: String {
            switch self {
            case .unlimited: return "不限制"
            case .thirtyDays: return "提前 30 天"
            case .sevenDays: return "提前 7 天"
            case .sameDay: return "仅当天"
            }
        }

        var limitDays: Int? {
            switch self {
            case .unlimited: return nil
            case .thirtyDays: return 30
            case .sevenDays: return 7
            case .sameDay: return 0
            }
        }

        /// 面板底部的解释文案
        var summary: String {
            switch self {
            case .unlimited: return "只要有未来倒计时，猫就会念"
            case .sameDay: return "只在事件当天念一句"
            default: return "事件进入 \(limitDays ?? 0) 天内才开始念"
            }
        }
    }

    /// 倒计时播报间隔：以分钟为单位，所以既能「每 30 分钟」也能「每天」
    enum CountdownInterval {
        /// 预设档位（分钟）：30 分钟 / 1 小时 / 每天 / 每 3 天，其余走「自定义」
        static let presets = [30, 60, 1440, 4320]
        static let defaultMinutes = 1440
        static let minMinutes = 5
        static let maxMinutes = 43200          // 30 天

        static func clamp(_ minutes: Int) -> Int {
            min(max(minutes, minMinutes), maxMinutes)
        }

        static func isPreset(_ minutes: Int) -> Bool { presets.contains(minutes) }

        /// 30 分钟 / 1 小时 / 每天 / 每 3 天 / 每 12 小时
        static func label(_ minutes: Int) -> String {
            if minutes >= 1440, minutes % 1440 == 0 {
                let days = minutes / 1440
                return days == 1 ? "每天" : "每 \(days) 天"
            }
            if minutes >= 60 {
                if minutes % 60 == 0 {
                    let hours = minutes / 60
                    return hours == 1 ? "1 小时" : "\(hours) 小时"
                }
                return "\(minutes) 分钟"
            }
            return "\(minutes) 分钟"
        }

        /// 一句话节奏说明：每 30 分钟一次 / 每天一次
        static func phrase(_ minutes: Int) -> String {
            minutes == 1440 ? "每天一次" : "每 \(label(minutes))一次"
        }
    }

    /// 学习计时中每多久播报一次已学时长
    enum StudyInterval {
        /// 预设档位（分钟），最后一档「自定义」由用户输入任意分钟数
        static let presets = [5, 10, 15, 30]
        static let defaultMinutes = 15
        static let minMinutes = 1
        static let maxMinutes = 240

        static func clamp(_ minutes: Int) -> Int {
            min(max(minutes, minMinutes), maxMinutes)
        }

        static func isPreset(_ minutes: Int) -> Bool { presets.contains(minutes) }
    }

    // MARK: 状态
    private(set) var countdownEnabled: Bool = true
    private(set) var countdownLead: CountdownLead = .sevenDays
    private(set) var countdownIntervalMinutes: Int = CountdownInterval.defaultMinutes
    private(set) var studyEnabled: Bool = true
    private(set) var studyIntervalMinutes: Int = StudyInterval.defaultMinutes

    /// 当前间隔不在预设档位里 → 走的是「自定义」
    var isStudyIntervalCustom: Bool { !StudyInterval.isPreset(studyIntervalMinutes) }
    var isCountdownIntervalCustom: Bool { !CountdownInterval.isPreset(countdownIntervalMinutes) }

    /// 任何一项被改动后回调（面板重绘 / 控制器重置播报节奏）
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() { load() }

    // MARK: 读写
    private func load() {
        if let v = defaults.object(forKey: PrefKey.cdRemindEnabled) as? Bool {
            countdownEnabled = v
        }
        if let v = defaults.object(forKey: PrefKey.cdRemindLead) as? Int,
           let e = CountdownLead(rawValue: v) {
            countdownLead = e
        }
        if let v = defaults.object(forKey: PrefKey.cdRemindInterval) as? Int,
           (CountdownInterval.minMinutes...CountdownInterval.maxMinutes).contains(v) {
            countdownIntervalMinutes = v
        }
        if let v = defaults.object(forKey: PrefKey.studyRemindEnabled) as? Bool {
            studyEnabled = v
        }
        if let v = defaults.object(forKey: PrefKey.studyRemindInterval) as? Int,
           (StudyInterval.minMinutes...StudyInterval.maxMinutes).contains(v) {
            studyIntervalMinutes = v
        }
    }

    private func commit() {
        defaults.set(countdownEnabled, forKey: PrefKey.cdRemindEnabled)
        defaults.set(countdownLead.rawValue, forKey: PrefKey.cdRemindLead)
        defaults.set(countdownIntervalMinutes, forKey: PrefKey.cdRemindInterval)
        defaults.set(studyEnabled, forKey: PrefKey.studyRemindEnabled)
        defaults.set(studyIntervalMinutes, forKey: PrefKey.studyRemindInterval)
        onChange?()
    }

    func setCountdownEnabled(_ v: Bool) {
        guard v != countdownEnabled else { return }
        countdownEnabled = v
        commit()
    }

    func setCountdownLead(_ v: CountdownLead) {
        guard v != countdownLead else { return }
        countdownLead = v
        commit()
    }

    func setCountdownInterval(minutes: Int) {
        let v = CountdownInterval.clamp(minutes)
        guard v != countdownIntervalMinutes else { return }
        countdownIntervalMinutes = v
        commit()
    }

    /// 距上次播报是否已经过了设定的间隔
    func countdownIntervalElapsed(since last: Date?) -> Bool {
        guard let last else { return true }
        return Date().timeIntervalSince(last) >= Double(countdownIntervalMinutes) * 60
    }

    func setStudyEnabled(_ v: Bool) {
        guard v != studyEnabled else { return }
        studyEnabled = v
        commit()
    }

    func setStudyInterval(minutes: Int) {
        let v = StudyInterval.clamp(minutes)
        guard v != studyIntervalMinutes else { return }
        studyIntervalMinutes = v
        commit()
    }

    /// 事件是否落在「开始提醒」的范围里
    func isInRange(days: Int) -> Bool {
        guard let limit = countdownLead.limitDays else { return true }
        return days <= limit
    }
}

// MARK: - 提醒设置页
/// 与日历 / 列表同一套手绘风格：分段选项用手绘 chip，开关是手绘胶囊。
final class ReminderSettingsView: NSView {
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var onChange: (() -> Void)?
    /// 点「自定义」→ 由面板弹输入框（面板需要临时关闭「失焦即关」）
    var onCustomStudyInterval: (() -> Void)?
    var onCustomCountdownInterval: (() -> Void)?

    private let settings: ReminderSettings
    private let store: CountdownStore

    override var isFlipped: Bool { true }

    // 布局缓存（每次 draw / 点击前重算）
    private var cdHeaderY: CGFloat = 0
    private var cdToggleY: CGFloat = 0
    private var cdToggleRect = NSRect.zero
    private var cdLeadLabelY: CGFloat = 0
    private var cdLeadChips: [(rect: NSRect, item: ReminderSettings.CountdownLead)] = []
    private var cdIntLabelY: CGFloat = 0
    private var cdIntChips: [(rect: NSRect, minutes: Int?, title: String)] = []
    private var previewY: CGFloat = 0
    private var studyHeaderY: CGFloat = 0
    private var studyToggleY: CGFloat = 0
    private var studyToggleRect = NSRect.zero
    private var studyLabelY: CGFloat = 0
    private var studyChips: [(rect: NSRect, minutes: Int?, title: String)] = []
    private var footerY: CGFloat = 0

    private var mousePoint: NSPoint?

    private let sidePad: CGFloat = 20
    private let chipH: CGFloat = 26
    private let chipGap: CGFloat = 6
    private let toggleW: CGFloat = 40
    private let toggleH: CGFloat = 22

    init(settings: ReminderSettings, store: CountdownStore) {
        self.settings = settings
        self.store = store
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: 布局
    private func chipRow(y: CGFloat, count: Int) -> [NSRect] {
        let total = bounds.width - sidePad * 2
        let w = (total - chipGap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            NSRect(x: sidePad + CGFloat(i) * (w + chipGap), y: y, width: w, height: chipH)
        }
    }

    private func computeLayout() {
        let w = bounds.width
        var y: CGFloat = 8

        cdHeaderY = y
        y += 22
        cdToggleY = y
        cdToggleRect = NSRect(x: w - sidePad - toggleW, y: y, width: toggleW, height: toggleH)
        y += 30

        cdLeadLabelY = y
        y += 16
        cdLeadChips = chipRow(y: y, count: ReminderSettings.CountdownLead.allCases.count)
            .enumerated().map { (i, r) in (rect: r, item: ReminderSettings.CountdownLead(rawValue: i)!) }
        y += chipH + 12

        cdIntLabelY = y
        y += 16
        let cdPresets = ReminderSettings.CountdownInterval.presets
        let cdCount = cdPresets.count + 1
        let cdRects = chipRow(y: y, count: cdCount)
        var cdChips: [(rect: NSRect, minutes: Int?, title: String)] = []
        for (i, m) in cdPresets.enumerated() {
            let label = ReminderSettings.CountdownInterval.label(m)
            cdChips.append((rect: cdRects[i], minutes: m, title: label))
        }
        cdChips.append((rect: cdRects[cdCount - 1], minutes: nil, title: "自定义"))
        cdIntChips = cdChips
        y += chipH + 10

        previewY = y
        y += 22 + 20

        studyHeaderY = y
        y += 22
        studyToggleY = y
        studyToggleRect = NSRect(x: w - sidePad - toggleW, y: y, width: toggleW, height: toggleH)
        y += 30

        studyLabelY = y
        y += 16
        let presets = ReminderSettings.StudyInterval.presets
        let chipCount = presets.count + 1
        let rects = chipRow(y: y, count: chipCount)
        var chips: [(rect: NSRect, minutes: Int?, title: String)] = []
        for (i, m) in presets.enumerated() {
            chips.append((rect: rects[i], minutes: m, title: "\(m) 分钟"))
        }
        chips.append((rect: rects[chipCount - 1], minutes: nil, title: "自定义"))
        studyChips = chips
        y += chipH + 16

        footerY = y
    }

    // MARK: 绘制
    override func draw(_ dirtyRect: NSRect) {
        computeLayout()
        let scale = ToolStyle.backingScale(self)

        // ── 未来倒计时提醒
        drawSection("未来倒计时提醒", at: cdHeaderY)
        drawToggle(cdToggleRect, on: settings.countdownEnabled)
        label("开启提醒", x: sidePad, y: cdToggleY + 3, size: 13, weight: .medium,
              color: .labelColor, enabled: true)

        let cdOn = settings.countdownEnabled
        label("开始提醒", x: sidePad, y: cdLeadLabelY, size: 11, weight: .regular,
              color: .secondaryLabelColor, enabled: cdOn)
        for chip in cdLeadChips {
            drawChip(chip.rect, title: chip.item.title,
                     selected: chip.item == settings.countdownLead, enabled: cdOn)
        }

        label("提醒间隔", x: sidePad, y: cdIntLabelY, size: 11, weight: .regular,
              color: .secondaryLabelColor, enabled: cdOn)
        let cdValueText = ReminderSettings.CountdownInterval
            .phrase(settings.countdownIntervalMinutes)
        let cdValueStr = ToolStyle.text(cdValueText, font: NSFont.systemFont(ofSize: 10.5),
                                        color: cdOn ? accent : NSColor.tertiaryLabelColor)
        let cdValueSize = cdValueStr.size()
        cdValueStr.draw(at: NSPoint(x: bounds.width - sidePad - cdValueSize.width, y: cdIntLabelY + 1))
        for chip in cdIntChips {
            let selected = chip.minutes == nil
                ? settings.isCountdownIntervalCustom
                : chip.minutes == settings.countdownIntervalMinutes
            drawChip(chip.rect, title: chip.title, selected: selected, enabled: cdOn)
        }

        // 当前状态一句话：设置改完立刻能看到影响
        let preview = previewText()
        label(preview.0, x: sidePad, y: previewY, size: 10.5, weight: .regular,
              color: preview.1, enabled: true)

        // ── 学习时长提醒
        drawSection("打卡时长提醒", at: studyHeaderY)
        drawToggle(studyToggleRect, on: settings.studyEnabled)
        label("打卡时播报", x: sidePad, y: studyToggleY + 3, size: 13, weight: .medium,
              color: .labelColor, enabled: true)

        let stOn = settings.studyEnabled
        label("播报间隔", x: sidePad, y: studyLabelY, size: 11, weight: .regular,
              color: .secondaryLabelColor, enabled: stOn)
        // 右侧说明：预设显示「每 15 分钟」，自定义显示实际分钟数
        let valueText = "每 \(settings.studyIntervalMinutes) 分钟播报"
        let valueStr = ToolStyle.text(valueText, font: NSFont.systemFont(ofSize: 10.5),
                                      color: stOn ? accent : NSColor.tertiaryLabelColor)
        let valueSize = valueStr.size()
        valueStr.draw(at: NSPoint(x: bounds.width - sidePad - valueSize.width, y: studyLabelY + 1))

        for chip in studyChips {
            let selected = chip.minutes == nil
                ? settings.isStudyIntervalCustom
                : chip.minutes == settings.studyIntervalMinutes
            drawChip(chip.rect, title: chip.title, selected: selected, enabled: stOn)
        }

        // ── 底部说明
        let tip = "关闭后猫不再主动说话；菜单栏猫头图标里的「提醒一下未来倒计时」仍可手动播报。"
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: tip, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: para,
        ])
        attr.draw(in: NSRect(x: sidePad, y: footerY,
                             width: bounds.width - sidePad * 2, height: 34))

        // 分隔线（两段之间的呼吸感）
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: sidePad, y: ToolStyle.px(studyHeaderY - 14, scale),
               width: bounds.width - sidePad * 2, height: 1).fill()
    }

    private func previewText() -> (String, NSColor) {
        guard let first = store.upcoming().first else {
            return ("还没有未来倒计时", .tertiaryLabelColor)
        }
        let base = "最近：\(first.event.title) · \(first.days == 0 ? "今天" : "\(first.days) 天后")"
        if !settings.countdownEnabled {
            return (base + "（提醒已关闭）", .tertiaryLabelColor)
        }
        if !settings.isInRange(days: first.days) {
            return (base + "（还不在提醒范围内）", .tertiaryLabelColor)
        }
        return (base + " · 在提醒范围内", settings.countdownLead.limitDays == nil ? .secondaryLabelColor : accent)
    }

    private func drawSection(_ text: String, at y: CGFloat) {
        accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: sidePad, y: y + 6, width: 5, height: 5)).fill()
        label(text, x: sidePad + 11, y: y, size: 11, weight: .semibold,
              color: .secondaryLabelColor, enabled: true)
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
                       weight: NSFont.Weight, color: NSColor, enabled: Bool) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attr = ToolStyle.text(text, font: font,
                                  color: enabled ? color : color.withAlphaComponent(0.4))
        attr.draw(at: NSPoint(x: x, y: y))
    }

    private func drawToggle(_ rect: NSRect, on: Bool) {
        let track = on ? accent : NSColor.labelColor.withAlphaComponent(0.16)
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        let d = rect.height - 4
        let knob = NSRect(x: on ? rect.maxX - d - 2 : rect.minX + 2,
                          y: rect.minY + 2, width: d, height: d)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    private func drawChip(_ rect: NSRect, title: String, selected: Bool, enabled: Bool) {
        let hovered = enabled && (mousePoint.map { rect.contains($0) } ?? false)
        if selected {
            accent.withAlphaComponent(enabled ? 1.0 : 0.25).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        } else {
            let alpha: CGFloat = enabled ? (hovered ? 0.12 : 0.07) : 0.04
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        let color: NSColor
        if selected {
            color = enabled ? ToolStyle.onAccent : ToolStyle.onAccent.withAlphaComponent(0.35)
        } else {
            color = enabled ? .labelColor : NSColor.tertiaryLabelColor
        }
        let font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        let str = ToolStyle.text(title, font: font, color: color)
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - 0.5))
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
        mousePoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mousePoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        computeLayout()
        let p = convert(event.locationInWindow, from: nil)

        if cdToggleRect.contains(p) {
            settings.setCountdownEnabled(!settings.countdownEnabled)
            notifyChange()
            return
        }
        if studyToggleRect.contains(p) {
            settings.setStudyEnabled(!settings.studyEnabled)
            notifyChange()
            return
        }

        if settings.countdownEnabled {
            if let hit = cdLeadChips.first(where: { $0.rect.contains(p) }) {
                settings.setCountdownLead(hit.item)
                notifyChange()
                return
            }
            if let hit = cdIntChips.first(where: { $0.rect.contains(p) }) {
                if let m = hit.minutes {
                    settings.setCountdownInterval(minutes: m)
                    notifyChange()
                } else {
                    onCustomCountdownInterval?()
                }
                return
            }
        }

        if settings.studyEnabled,
           let hit = studyChips.first(where: { $0.rect.contains(p) }) {
            if let m = hit.minutes {
                settings.setStudyInterval(minutes: m)
                notifyChange()
            } else {
                onCustomStudyInterval?()     // 交给面板弹输入框
            }
            return
        }
    }

    private func notifyChange() {
        needsDisplay = true
        onChange?()
    }

    /// 外部（例如打开面板时）刷新一次
    func refresh() { needsDisplay = true }
}
