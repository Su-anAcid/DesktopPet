# Prompt：给 DesktopPet 加「打卡日历 + 事件倒计时」

> 复制下面分隔线之间的全部内容，直接粘给编码助手（Claude Code / Codex / Cursor 都行）。
> 上下文按当前仓库的实际情况写好，不需要再补充项目说明。

---

## 任务

在 `~/WorkBuddy/workspace/DesktopPet` 这个 macOS 桌宠项目里新增两个小工具，目标版本 v1.1.0：

1. **打卡日历**：每天点一次「今天打卡」，猫会开心，日历留痕，连续天数累计；
2. **事件倒计时**：记下未来的日子（生日、上线、考试），随时看到还剩几天。

两者共用**同一个 320×400 的面板**，顶部用分段控件切换，数据全部本地存储。请先通读 `Sources/App.swift` 和 `Sources/SpriteData.swift` 再动手，不要凭想象猜接口。

## 项目现状（重要约束）

- 纯 Swift + AppKit，零第三方依赖，**不用 SwiftUI、不用 xib/storyboard**，所有界面代码绘制。
- 构建：`./build.sh`（开发构建并启动，产物 `build/DesktopPet.app`）；`./release.sh 1.1.0`（发布通用二进制 + DMG）。
- **`build.sh` 和 `release.sh` 里 `swiftc` 的源文件列表是硬编码的**（目前是 `Sources/SpriteData.swift Sources/App.swift`）。新增 `.swift` 文件必须同步改这两处的参数，否则链接时报 `undefined symbol`。这是本次改动最容易漏的一步。
- `Sources/App.swift`（约 890 行）关键结构：
  - `PetController: NSObject` 是唯一控制器，持有 `panel: NSPanel`（`.borderless` + `.nonactivatingPanel`，`level = .floating`）和 `petView: PetView`。
  - 偏好统一走 `enum PrefKey` + `UserDefaults.standard`，集中在 `loadPrefs()` / `savePrefs()` 读写。
  - 菜单两套：`makeMenu()`（右键点猫）和 `makeStatusMenu()`（菜单栏图标，`menuNeedsUpdate` 每次展开前重建）。
  - **菜单项必须显式 `target = self`，且 menu 设 `autoenablesItems = false`。** `PetController` 不在响应者链里，漏了就会被系统整项置灰（1.0.1 修过这个 bug，不要踩回去）。
  - 情绪反馈现成能力：`pat()`、`loveTicks`（爱心眼帧计数）、`spawnParticles(_ text: String, count: Int)`（文字粒子上浮）。
  - 主循环 `tick()` 由 30Hz 的 `Timer` 驱动；`showAbout()` 是现成的弹窗写法参考（含 `NSApp.activate(ignoringOtherApps: true)`）。
- 调色板在 `Sources/SpriteData.swift`：`petPalettes: [Palette]`，每套有 `colors: [String: NSColor]`，其中键 `"g"` 是琥珀色眼睛。**两个工具的主色都取 `petPalettes[paletteIndex].colors["g"]`**，跟着当前毛色走；取不到时回退 `NSColor.controlAccentColor`。
- 应用是 `LSUIElement = true`（无 Dock 图标），弹窗必须主动 `NSApp.activate` 才会到前台。

## 一、打卡日历

### 1.1 打卡行为

- 一天只能打一次，且只能打「今天」（本地时区自然日）。**不做补卡，不接受未来日期。**
- 入口：右键菜单「行为」分组之前、菜单栏菜单「显示/隐藏猫咪」之后，各加一项 `打卡日历…`，点击后面板打开并自动切到「打卡」tab。
- 打卡页底部主按钮为 `今天打卡`；当天已打卡则变成 `已打卡 ✓` 并禁用。
- 打卡成功时：
  - 日历当天格子立即变实心，带一次 0.2s 的缩放入场动画；
  - 猫进入爱心眼约 3 秒（`loveTicks ≈ 90`），并 `spawnParticles("❤", count: 4)`；
  - 若连续天数命中里程碑（1 / 3 / 7 / 14 / 21 / 30 / 50 / 100 / 200 / 365），额外 `spawnParticles("连续 N 天！", count: 1)`。
- 重复打卡（当天已打过）：不写数据，猫冒出 `今天已经打过卡啦` 粒子；若面板开着，面板左右轻摇一次（±6pt，0.25s）。

### 1.2 日历界面

- 面板 320 × 400 pt，出现在猫窗口旁边：优先右侧，右侧放不下放左侧，都不行就居中；最后 clamp 进 `visibleFrame`。
- 顶部 28pt 高分段控件 `打卡 | 倒计时`（`NSSegmentedControl`，`.rounded` 样式，宽 156，居中）。
- 日历头部一行：`‹   2026 年 11 月   ›`，箭头切月。**不允许翻到当前月之后**，当月时「下月」按钮置灰禁用。
- 星期表头 `一 二 三 四 五 六 日`（周一开头），11pt，`secondaryLabelColor`。
- 月历 7 列 × 最多 6 行，单元格 34×34，行距 4。只画本月日期，前后用空格子补齐（不显示邻月数字，减少噪音）。
- 单元格状态：
  - **已打卡**：主色填充 30×30 圆角方块（圆角 8），数字用深色（约 `#1F1710`）压在色块上——**不要往格子里塞爪印**，30pt 的格子容不下两个视觉元素；
  - **今天未打卡**：1.5pt 主色描边 + 主色数字；
  - **未来日期**：30% 透明度，不可点；
  - **普通过去日期**：`labelColor` 数字；
  - **hover**：格子底部 10% `quaternaryLabelColor` 圆角高亮。
- 点击任意日期：只做视觉选中反馈（该格加一圈细描边 + 底部小字显示「11 月 3 日 · 已打卡」这类状态），**绝不能借此补卡**。
- 底部信息区（上方 1pt 分隔线）：
  - 左侧：`连续 12 天`（数字 28pt semibold rounded，单位 12pt）；下一行 `最长 21 天 · 累计 87 天`（11pt secondary）。
  - 右侧：主按钮，高 32、圆角 16、主色填充、**深色字** 13pt semibold（主色是偏亮的琥珀，白字对比度不够）；按钮左侧带一个 8×8 像素爪印图标（`CGContext` 画 3 个圆点 + 一块掌垫，不要用 SF Symbol），这是整套 UI 里唯一的像素装饰。

### 1.3 打卡数据与统计

- 存储：`UserDefaults.standard`，新增 `PrefKey.checkinDates = "checkinDates"`，值为 `[String]`，元素格式 `yyyy-MM-dd`。
  - 生成日期键时**不要**裸用 `DateFormatter`；必须显式设置 `locale = Locale(identifier: "en_US_POSIX")` 与固定 `dateFormat`，否则在泰历 / 和历 / 佛教历区域会写出错误年份。更稳的写法：`Calendar.current.dateComponents([.year,.month,.day], from:)` + `String(format: "%04d-%02d-%02d", ...)`。
  - 写入前去重 + 升序；读取时过滤掉格式不合法的字符串，容错不崩。
- 统计口径（`CheckInStats`）：
  - `total`：去重天数，忽略未来日期；
  - `best`：升序扫描，相邻日期差 1 天则累加，取历史最大值；
  - `current`：今天已打卡 → 从今天往前数；今天没打但昨天打了 → 从昨天往前数（连击未断，只是今天待打卡）；否则 0。

## 二、事件倒计时

### 2.1 界面

- 同一个面板切到「倒计时」tab 后，内容区替换为事件列表（日历不显示，但状态保留）。
- 列表按「距今天数」升序：今天的最前，然后由近到远。
- 行高 52，行间 1pt 分隔线。行内容：
  - 左：标题 13pt（超长截断加省略号，最多约 14 个汉字）；下方日期小字 11pt secondary，格式 `12 月 24 日`，每年重复时追加 `· 每年`；
  - 右：天数数字 20pt semibold + 单位 `天` 10pt，与标题基线视觉居中。
- 天数文案：`0` → `今天`（主色文字 + 整行 8% 主色底）；`1` → `明天`；`≥2` → `N 天`。
- 已过去的一次性事件不再展示（数据保留，不清除）；每年重复的事件自动滚到下一次（今年已过就取明年）。
- 底部：`+ 添加事件` 按钮（通栏、高 32、圆角 16、主色 10% 背景 + 主色文字）。最多 20 条，满了按钮禁用并显示 `最多 20 个事件`。
- 空状态：居中一行 `还没有倒计时事件`（13pt secondary），下方是同一个添加按钮；不要画插图。

### 2.2 增删与校验

- 添加：点按钮弹 `NSAlert` + `accessoryView`（一个竖排 `NSStackView`）：
  - `NSTextField` 标题（占位符 `例如：妈妈的生日`，最长 30 字）；
  - `NSDatePicker`（`.textFieldAndStepper`，只取日期，默认今天，不允许早于今天）；
  - `NSButton(checkbox)` `每年重复`；
  - 确定前校验：标题非空、去重（同标题 + 同日期已存在则提示 `这个事件已经有了`）。校验失败时 `NSAlert` 不关闭并给出提示。
- 删除：鼠标悬停行尾出现 14pt `×` 按钮，点击直接删除（不弹二次确认），行 0.15s 淡出后列表上移。
- 事件模型：`CountdownEvent { id: UUID, title: String, dateKey: String, yearly: Bool }`，`Codable`，整存整取。

### 2.3 倒计时数据

- 存储：`UserDefaults.standard`，`PrefKey.countdownEvents = "countdownEvents"`，值为 `Data`（`JSONEncoder`）。解码失败就当空数组，**不要崩**。
- 天数算法：用 `Calendar.current.dateComponents([.day], from: startOfToday, to: startOfEventDay)`，**不要用 86400 秒硬算**，否则跨夏令时会差一天。
- 每年重复：按当前年份取该月日；若今年这天已过，取明年。2 月 29 日在平年落到 2 月 28 日。

## 三、共用规则

### 3.1 面板外观与行为

- `NSPanel`，`styleMask: [.titled, .closable, .fullSizeContentView]`，`titleVisibility = .hidden`，`titlebarAppearsTransparent = true`，`isMovableByWindowBackground = true`，`level = .floating`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`。
- 背景 `NSVisualEffectView`（`.hudWindow` + `.blendingMode = .behindWindow`）+ 20pt 圆角，深浅色自动跟随系统。
- 关闭：关闭按钮、ESC、或窗口失焦（`windowDidResignKey`）任一即可。`isReleasedWhenClosed = false`，复用同一个窗口实例。
- 打开时淡入（alpha 0 → 1，0.15s），并记住上次停留的 tab（`PrefKey.toolTab`）。
- 每次打开都重置到当前月、重算统计与倒计时天数。

### 3.2 与桌宠的联动

- 打卡与倒计时的交互**不得打断**猫当前的动作状态机（不要调 `enter(.idle)` / `play(...)` 之类），只叠加情绪反馈（`loveTicks` 与粒子）。
- 唯一例外：猫正在睡觉时打卡，先温柔唤醒到 idle 再给爱心眼。
- 今天有倒计时事件时：面板顶部（tab 下方）显示一段主色 10% 背景的提示带，高 24，文案 `今天：生日、项目上线`（超过 2 个时写 `今天：生日 等 3 个事件`）；同时猫冒一次 `今天：生日` 粒子。
- 同一事件同一天只提醒一次：把最后提醒的 `dayKey` 存进 `PrefKey.countdownNotifiedDay`，30Hz 的 `tick()` 里不要反复触发。

### 3.3 跨天

猫可能连续开机好几天。**不要在启动时把「今天」缓存成常量**。打开面板、每次打卡、以及 `tick()` 每 30 帧都重新取 `Date()` 与缓存的 dayKey 比对，变化就刷新：打卡按钮从 `已打卡 ✓` 变回 `今天打卡`、倒计时天数整体减 1、事件到期提醒重新武装。

时钟回拨 / 脏数据：统计时忽略晚于今天的日期，但**不要删除**数据，时间改回来自然恢复。

调试钩子：若环境变量 `DESKTOPPET_FAKE_TODAY=2026-11-04` 存在，则用它覆盖「今天」，方便自测跨天；生产环境无影响。

## 四、代码组织

- 新增 `Sources/CheckIn.swift`：
  - `DayKey`：dayKey ↔ `Date` 纯函数、天数差；
  - `CheckInStats`；
  - `CheckInStore`：`load` / `save` / `checkInToday` / `isChecked` / `stats` / `monthDays`；
  - `CheckInCalendarView: NSView`：自绘 + 命中测试，`onCheckIn` / `onSelectDay` 回调。
- 新增 `Sources/Countdown.swift`：
  - `CountdownEvent`、`CountdownStore`（增删、排序、下一次发生日、今日事件）；
  - `CountdownListView: NSView`：列表绘制 + hover 删除按钮（用 `NSTrackingArea`）+ `onAdd` 回调。
- 新增 `Sources/ToolsPanel.swift`：
  - `ToolsPanelController: NSObject, NSWindowDelegate`：窗口生命周期、定位、tab 切换、淡入；
  - 组装分段控件 + 两个内容视图 + 今日事件提示带。
- `App.swift` 只加三处：三个 `PrefKey`（`checkinDates` / `countdownEvents` / `toolTab`，外加 `countdownNotifiedDay`）、两个菜单项 + `@objc func openTools(_:)`、`tick()` 里的跨天检测。**不要把视图代码塞进 App.swift。**
- 三个新文件必须加进 `build.sh` 和 `release.sh` 的 `swiftc` 列表（放在 `Sources/App.swift` 之后）。

## 五、边界与质量要求

- 首次运行无数据：日历全空、连续 0 天、累计 0 天；倒计时显示空状态文案。都不画插图。
- 日历始终按 6 行（42 格）占位，切换月份窗口高度不跳动；切 tab 也不改变窗口尺寸。
- 1 月 ↔ 12 月跨年正确；闰年 2 月 29 正确；月末 31 号 → 次日 1 号判断为相邻 1 天。
- 深色 / 浅色模式都清晰可读；Retina 下描边与像素爪印发虚视为不合格（按 `backingScaleFactor` 对齐物理像素）。
- 不引入任何依赖、资源文件、网络请求或通知权限。
- 注释与 UI 文案用中文，风格对齐现有代码（`// MARK: -` 分段、`private` 收窄可见性、不用强制解包）。

## 六、非目标（明确不要做）

- 不做补卡、撤销打卡、编辑历史。
- 不做事件编辑、拖拽排序、每月/每周重复、农历。
- 不做提醒推送 / 系统通知 / 音效。
- 不做 iCloud 同步、多设备、导入导出。
- 不改 `Windows/` 目录（但不要破坏 Windows 构建脚本）。
- 不引入 SwiftUI、不新增 xib。

## 七、验收清单（逐条自测后回报结果）

1. `./build.sh` 一次通过，无新增 warning。
2. 右键猫 → `打卡日历…` → 面板出现在猫旁边，停在「打卡」tab，显示当前月，今天有描边。
3. 点 `今天打卡` → 按钮变 `已打卡 ✓`、当天格子变实心、猫出现爱心眼与 ❤ 粒子。
4. 关窗再开、退出 App 重开，打卡记录都还在。
5. 用 `DESKTOPPET_FAKE_TODAY` 把今天设为明天 → 重开面板，按钮恢复 `今天打卡`，连续天数 +1。
6. 模拟「昨天 + 今天」→ 连续 2 天；跳过一天再打 → 连续回到 1 天。
7. 当月时「下月」箭头禁用；1 月/12 月跨年翻页正常。
8. 切到「倒计时」tab，添加 `项目上线 / 11 月 20 日` → 列表显示 `17 天` 且排在最前（假设今天 11 月 3 日）。
9. 添加每年重复的生日 → 日期显示 `· 每年`，跨年后自动滚到明年；2 月 29 日的事件在平年显示 2 月 28 日。
10. 删除一条事件 → 立刻消失，重启后不复现。
11. 把事件日期设为今天 → 顶部提示带出现、行显示 `今天`、猫冒一次粒子；重启 App 同一天不再重复提醒。
12. 关窗再开，仍停在上次的 tab。
13. 深/浅色、三档大小、三种毛色下，主色与文字对比度都正常。
14. 菜单栏图标菜单里两个入口都能打开对应 tab。
15. 猫睡觉时打卡 → 唤醒 + 爱心眼，状态机不卡死（之后还能正常散步/睡觉）。

## 八、交付物

- 改动文件：`Sources/CheckIn.swift`、`Sources/Countdown.swift`、`Sources/ToolsPanel.swift`（均新增）、`Sources/App.swift`、`build.sh`、`release.sh`、`CHANGELOG.md`（新增 1.1.0 段）、`README.md`（特性列表补两条玩法）。
- 版本号：`build.sh` 的 `VERSION` 与 `Support/Info.plist` 的 `CFBundleShortVersionString` 改为 `1.1.0`。
- 完成后实际跑一次 `./build.sh`，并把验收清单 1–4 的真实结果贴出来；没验证的项要说明原因，不要假装通过。
