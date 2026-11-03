import AppKit

// MARK: - 学习时长
/// 按「本地自然日」累计学习秒数。
/// 计时由主循环以 30Hz 驱动，每次只吃很小的一段增量，所以不会像
/// 起止时间相减那样：合盖休眠一夜、或时钟被改，就把整晚算成学习时间。
final class StudyStore {
    private(set) var daySeconds: [String: Int] = [:]
    private(set) var isRunning = false

    private var lastTickAt: Date?
    private var remainder: Double = 0        // 不足 1 秒的零头，攒够再进位
    private var lastFlushAt = Date()

    /// 单次增量上限：超过这个值说明中间休眠/卡顿了，只认这一小段
    private let maxDelta: TimeInterval = 2.0
    /// 落盘间隔：崩溃最多丢 15 秒
    private let flushInterval: TimeInterval = 15

    init() { load() }

    // MARK: 读写
    func load() {
        let raw = UserDefaults.standard.dictionary(forKey: PrefKey.studySeconds) ?? [:]
        var out: [String: Int] = [:]
        for (key, value) in raw {
            guard DayKey.parse(key) != nil else { continue }   // 脏数据一律丢掉
            let n: Int
            if let i = value as? Int {
                n = i
            } else if let d = value as? Double {
                n = Int(d)
            } else if let s = value as? String, let i = Int(s) {
                n = i
            } else {
                continue
            }
            if n > 0 { out[key] = n }
        }
        daySeconds = out
    }

    func save() {
        UserDefaults.standard.set(daySeconds, forKey: PrefKey.studySeconds)
        lastFlushAt = Date()
    }

    func seconds(for key: String) -> Int { daySeconds[key] ?? 0 }

    func minutes(for key: String) -> Int { seconds(for: key) / 60 }

    var todaySeconds: Int { seconds(for: DayKey.todayKey()) }

    var totalSeconds: Int { daySeconds.values.reduce(0, +) }

    // MARK: 计时
    func start() {
        guard !isRunning else { return }
        isRunning = true
        remainder = 0
        lastTickAt = Date()
        lastFlushAt = Date()
    }

    func pause() {
        guard isRunning else { return }
        tick(now: Date())          // 结算最后一段
        isRunning = false
        lastTickAt = nil
        save()
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    /// 由 App 的主循环驱动（30Hz）
    func tick(now: Date = Date()) {
        guard isRunning else { return }
        guard let last = lastTickAt else { lastTickAt = now; return }
        let delta = now.timeIntervalSince(last)
        lastTickAt = now
        guard delta > 0 else { return }
        accrue(min(delta, maxDelta))
        if now.timeIntervalSince(lastFlushAt) >= flushInterval { save() }
    }

    private func accrue(_ seconds: Double) {
        remainder += seconds
        let whole = Int(remainder)
        guard whole > 0 else { return }
        remainder -= Double(whole)
        // 每次都用「当前这天」记账：跨零点时会自动分到新的日期上
        daySeconds[DayKey.todayKey(), default: 0] += whole
    }

    // MARK: 展示
    /// 面板里的完整写法：0 分钟 / 25 分钟 / 1 小时 20 分
    static func format(_ seconds: Int) -> String {
        if seconds <= 0 { return "0 分钟" }
        if seconds < 60 { return "不到 1 分钟" }
        let total = seconds / 60
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m) 分钟" }
        if m == 0 { return "\(h) 小时" }
        return "\(h) 小时 \(m) 分"
    }

    /// 日历格子里的极简写法：45m / 2h / 1.5h（30pt 宽塞得下）
    static func compact(minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = Double(minutes) / 60
        if abs(hours.rounded() - hours) < 0.05 { return "\(Int(hours.rounded()))h" }
        return String(format: "%.1fh", hours)
    }
}

// MARK: - 时长色阶
/// 用颜色区分「那天学得久不久」：浅沙 → 琥珀 → 橙 → 砖红 → 深赭。
/// 与猫的琥珀色眼睛同一族，深色/浅色外观下都能看出层次。
enum StudyTier {
    /// 0 = 没有计时记录；1~5 按分钟递增
    static func level(minutes: Int) -> Int {
        if minutes <= 0 { return 0 }
        if minutes < 30 { return 1 }
        if minutes < 60 { return 2 }
        if minutes < 120 { return 3 }
        if minutes < 240 { return 4 }
        return 5
    }

    /// 说明文字：0 分钟 / 30 分钟以内 / 30 分~1 小时 / 1~2 小时 / 2~4 小时 / 4 小时以上
    static func label(_ level: Int) -> String {
        switch level {
        case 0: return "没有计时"
        case 1: return "30 分钟以内"
        case 2: return "30 分钟 ~ 1 小时"
        case 3: return "1 ~ 2 小时"
        case 4: return "2 ~ 4 小时"
        default: return "4 小时以上"
        }
    }

    private static let heat: [NSColor] = [
        .clear,
        NSColor(srgbRed: 0.97, green: 0.86, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.96, green: 0.74, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.55, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.78, green: 0.36, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.60, green: 0.22, blue: 0.10, alpha: 1),
    ]

    /// 打卡格的填充色：有计时就按色阶，没有计时沿用主色
    static func fill(_ level: Int, accent: NSColor) -> NSColor {
        level <= 0 ? accent : heat[min(level, heat.count - 1)]
    }

    /// 填充块上的文字：浅色阶用深字，深色阶用浅字
    static func onFill(_ level: Int) -> NSColor {
        level >= 4 ? NSColor(srgbRed: 0.99, green: 0.97, blue: 0.94, alpha: 1) : ToolStyle.onAccent
    }

    /// 未打卡但有计时：同一个色阶压深一点当文字色，浅底深底都看得清
    static func text(_ level: Int) -> NSColor {
        guard level > 0 else { return .secondaryLabelColor }
        return heat[min(level, heat.count - 1)].blended(withFraction: 0.3, of: .black)
            ?? NSColor.secondaryLabelColor
    }
}
