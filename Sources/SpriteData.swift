import AppKit

// MARK: - 像素画布：用几何形状光栅化生成高精度像素画
// 64 x 64 网格，渲染时每格 5pt → 320 x 320
// 图例: . 透明 | k 描边 | o 主体 | d 深色斑纹 | w 白色 | p 粉色/表情 | g 眼睛

typealias Frame = [String]

let GRID_W = 64
let GRID_H = 64

struct PixelCanvas {
    private var g: [[Character]]

    init() {
        g = Array(repeating: Array(repeating: Character("."), count: GRID_W), count: GRID_H)
    }

    subscript(x: Int, y: Int) -> Character {
        get { (y >= 0 && y < GRID_H && x >= 0 && x < GRID_W) ? g[y][x] : Character(".") }
        set { if x >= 0 && x < GRID_W && y >= 0 && y < GRID_H { g[y][x] = newValue } }
    }

    mutating func plot(_ x: Double, _ y: Double, _ ch: Character) {
        self[Int(x.rounded()), Int(y.rounded())] = ch
    }

    mutating func ellipse(cx: Double, cy: Double, rx: Double, ry: Double, _ ch: Character) {
        let y0 = max(0, Int((cy - ry).rounded(.down))), y1 = min(GRID_H - 1, Int((cy + ry).rounded(.up)))
        let x0 = max(0, Int((cx - rx).rounded(.down))), x1 = min(GRID_W - 1, Int((cx + rx).rounded(.up)))
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = (Double(x) + 0.5 - cx) / rx
                let dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1.0 { self[x, y] = ch }
            }
        }
    }

    mutating func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ ch: Character) {
        let y0 = max(0, Int(y.rounded(.down))), y1 = min(GRID_H - 1, Int((y + h).rounded(.up)) - 1)
        let x0 = max(0, Int(x.rounded(.down))), x1 = min(GRID_W - 1, Int((x + w).rounded(.up)) - 1)
        for y in y0...y1 { for x in x0...x1 { self[x, y] = ch } }
    }

    mutating func triangle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ ch: Character) {
        func sign(_ p: (Double, Double), _ s: (Double, Double), _ e: (Double, Double)) -> Double {
            return (p.0 - e.0) * (s.1 - e.1) - (s.0 - e.0) * (p.1 - e.1)
        }
        let minX = max(0, Int(min(a.0, b.0, c.0).rounded(.down)))
        let maxX = min(GRID_W - 1, Int(max(a.0, b.0, c.0).rounded(.up)))
        let minY = max(0, Int(min(a.1, b.1, c.1).rounded(.down)))
        let maxY = min(GRID_H - 1, Int(max(a.1, b.1, c.1).rounded(.up)))
        for y in minY...maxY {
            for x in minX...maxX {
                let p = (Double(x) + 0.5, Double(y) + 0.5)
                let s1 = sign(p, a, b), s2 = sign(p, b, c), s3 = sign(p, c, a)
                let neg = s1 < 0 || s2 < 0 || s3 < 0
                let pos = s1 > 0 || s2 > 0 || s3 > 0
                if !(neg && pos) { self[x, y] = ch }
            }
        }
    }

    mutating func disc(cx: Double, cy: Double, r: Double, _ ch: Character) {
        ellipse(cx: cx, cy: cy, rx: r, ry: r, ch)
    }

    /// 带体积光影的椭圆：光从左上来 → 左上提亮(l)、右下靠边压暗(s)，中间保持主体色(o)
    /// 用归一化坐标算「球面」明暗，画出来是鼓起来的立体感，而不是平涂
    mutating func shadedEllipse(cx: Double, cy: Double, rx: Double, ry: Double,
                                base: Character = "o",
                                dark: Character = "s",
                                light: Character = "l",
                                lightDir: (Double, Double) = (-0.5, -0.87),
                                rim: Double = 0.74,
                                highlight: Double = 0.5) {
        let (lx, ly) = lightDir
        let y0 = max(0, Int((cy - ry).rounded(.down))), y1 = min(GRID_H - 1, Int((cy + ry).rounded(.up)))
        let x0 = max(0, Int((cx - rx).rounded(.down))), x1 = min(GRID_W - 1, Int((cx + rx).rounded(.up)))
        for y in y0...y1 {
            for x in x0...x1 {
                let nx = (Double(x) + 0.5 - cx) / rx
                let ny = (Double(y) + 0.5 - cy) / ry
                let r = (nx * nx + ny * ny).squareRoot()
                if r > 1.0 { continue }
                let facing = nx * lx + ny * ly          // 正 = 朝向光源
                if r > rim && facing < -0.15 {
                    self[x, y] = dark                    // 右下外缘的暗部
                } else if facing > highlight {
                    self[x, y] = light                   // 左上受光面
                } else {
                    self[x, y] = base
                }
            }
        }
    }

    /// 给已画好的区域在「下缘」补一道暗边，用于白肚皮、白爪这类浅色部位
    mutating func shadeBottom(over chars: Set<Character> = ["w"], depth: Int = 1, dark: Character = "s") {
        let orig = g
        for y in 0..<GRID_H {
            for x in 0..<GRID_W where chars.contains(orig[y][x]) {
                var below = 0
                while below < depth, y + below + 1 < GRID_H, chars.contains(orig[y + below + 1][x]) {
                    below += 1
                }
                if below < depth { g[y][x] = dark }
            }
        }
    }

    /// 整片身体的体积光影：按「同行/同列的相对位置」判明暗。
    /// 多个椭圆拼出的身体也不会出现内部接缝，光从左上打来。
    mutating func shadeSilhouette(over chars: Set<Character> = ["o"],
                                  dark: Character = "s",
                                  light: Character = "l",
                                  darkAt: Double = 0.30,
                                  lightAt: Double = 0.82,
                                  strength: (Double, Double) = (0.45, 0.55)) {
        let orig = g
        func isBody(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < GRID_W && y >= 0 && y < GRID_H && chars.contains(orig[y][x])
        }
        var out = g
        for y in 0..<GRID_H {
            for x in 0..<GRID_W where isBody(x, y) {
                var x0 = x, x1 = x
                while isBody(x0 - 1, y) { x0 -= 1 }
                while isBody(x1 + 1, y) { x1 += 1 }
                var y0 = y, y1 = y
                while isBody(x, y0 - 1) { y0 -= 1 }
                while isBody(x, y1 + 1) { y1 += 1 }
                let nx = x1 > x0 ? Double(x - x0) / Double(x1 - x0) : 0.5
                let ny = y1 > y0 ? Double(y - y0) / Double(y1 - y0) : 0.5
                let lit = (1 - nx) * strength.0 + (1 - ny) * strength.1   // 左上最亮
                if lit < darkAt {
                    out[y][x] = dark
                } else if lit > lightAt {
                    out[y][x] = light
                }
            }
        }
        g = out
    }

    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, thickness: Double, _ ch: Character) {
        let steps = Int(ceil(max(abs(x1 - x0), abs(y1 - y0)) * 2)) + 1
        for i in 0...steps {
            let t = Double(i) / Double(max(steps, 1))
            disc(cx: x0 + (x1 - x0) * t, cy: y0 + (y1 - y0) * t, r: thickness / 2, ch)
        }
    }

    /// 给所有形状自动加 1px 描边（只影响透明格子）
    /// skip 返回 true 的格子不描边，用于「脖子」这类本该与身体连成一体、不能出现线的部位
    mutating func addOutline(skip: (Int, Int) -> Bool = { _, _ in false }) {
        let orig = g
        for y in 0..<GRID_H {
            for x in 0..<GRID_W where orig[y][x] == "." {
                if skip(x, y) { continue }
                let filled = [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
                    let nx = x + dx, ny = y + dy
                    return nx >= 0 && nx < GRID_W && ny >= 0 && ny < GRID_H && orig[ny][nx] != "."
                }
                if filled { g[y][x] = "k" }
            }
        }
    }

    /// 内部像素表（供图层合成用）
    var cells: [[Character]] { g }

    /// 把一块独立图层按角度旋转后贴到本画布上（屏幕坐标，angle 为正 = 顺时针）
    /// 用逆映射 + 最近邻采样：像素画旋转后会带自然的阶梯边，正好是手绘倾斜的感觉
    mutating func compositeRotated(_ layer: [[Character]], degrees: Double, pivot: (Double, Double)) {
        let a = degrees * Double.pi / 180
        let ca = cos(a), sa = sin(a)
        for y in 0..<GRID_H {
            for x in 0..<GRID_W {
                let dx = Double(x) + 0.5 - pivot.0
                let dy = Double(y) + 0.5 - pivot.1
                let sx = pivot.0 + dx * ca + dy * sa
                let sy = pivot.1 - dx * sa + dy * ca
                let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                guard ix >= 0, ix < GRID_W, iy >= 0, iy < GRID_H else { continue }
                let ch = layer[iy][ix]
                if ch != "." { self[x, y] = ch }
            }
        }
    }

    func toFrame() -> Frame { g.map { String($0) } }
}

// MARK: - 表情类型
enum Expression {
    case normal      // 琥珀大眼
    case happy       // 弯弯笑眼 + 咧嘴
    case love        // 爱心眼
    case surprised   // 瞪大眼 + 圆嘴
    case closed      // 闭眼（睡觉 / 眨眼）
}

// MARK: - 正面趴卧小猫（尾巴可左右摆动）
func buildSitCat(eyes: Expression, tailUp: Bool) -> Frame {
    var c = PixelCanvas()

    // 蓬松尾巴（两个摆动方向，尾尖深色）
    if tailUp {
        c.line(48, 54, 57, 43.5, thickness: 4.8, "o")
        c.ellipse(cx: 58, cy: 41.8, rx: 3.3, ry: 3.3, "o")
        c.ellipse(cx: 59.6, cy: 40.4, rx: 2.3, ry: 2.3, "d")
    } else {
        c.line(48, 54, 58.5, 49, thickness: 4.8, "o")
        c.ellipse(cx: 59.8, cy: 48, rx: 3.3, ry: 3.3, "o")
        c.ellipse(cx: 61.2, cy: 46.8, rx: 2.2, ry: 2.2, "d")
    }

    // 身体（趴卧，宽而低）——带体积光影
    c.shadedEllipse(cx: 32, cy: 50, rx: 19, ry: 9)
    // 白胸脯
    c.ellipse(cx: 32, cy: 52.5, rx: 8.5, ry: 5.5, "w")
    // 前爪（白色圆爪）
    c.ellipse(cx: 25, cy: 58.5, rx: 4.6, ry: 3.2, "w")
    c.ellipse(cx: 39, cy: 58.5, rx: 4.6, ry: 3.2, "w")

    // 头（大圆脸）——带体积光影
    c.shadedEllipse(cx: 32, cy: 26, rx: 17.5, ry: 15.5, rim: 0.78, highlight: 0.42)
    // 腮边绒毛
    c.triangle((15.5, 29), (10.5, 32), (15.5, 35), "o")
    c.triangle((48.5, 29), (53.5, 32), (48.5, 35), "o")
    c.triangle((16, 24), (12.5, 26.5), (16, 29), "o")
    c.triangle((48, 24), (51.5, 26.5), (48, 29), "o")
    // 耳朵（正三角：平底朝下、尖端朝上）+ 耳内粉色
    c.triangle((17.5, 18), (28.5, 18), (21, 4), "o")
    c.triangle((35.5, 18), (46.5, 18), (43, 4), "o")
    c.triangle((19.8, 16.2), (26.2, 16.2), (22.2, 7.5), "p")
    c.triangle((37.8, 16.2), (44.2, 16.2), (41.8, 7.5), "p")
    // 额头虎斑
    c.rect(31, 11.5, 2, 6.5, "d")
    c.rect(26, 12.8, 2, 5, "d")
    c.rect(36, 12.8, 2, 5, "d")

    // 自动描边
    c.addOutline()

    // 白口鼻
    c.ellipse(cx: 32, cy: 33.5, rx: 6.8, ry: 4.6, "w")

    // 眼睛 / 表情
    switch eyes {
    case .normal:
        drawBigEye(&c, cx: 24.5, cy: 27.3)
        drawBigEye(&c, cx: 39.5, cy: 27.3)
    case .happy:
        // 弯弯笑眼 ∩
        for (bx, flip) in [(24.5, 1.0), (39.5, 1.0)] {
            _ = flip
            c.plot(bx - 3, 28.5, "k"); c.plot(bx - 2, 27.3, "k")
            c.plot(bx - 1, 26.5, "k"); c.plot(bx, 26.2, "k")
            c.plot(bx + 1, 26.5, "k"); c.plot(bx + 2, 27.3, "k"); c.plot(bx + 3, 28.5, "k")
        }
    case .love:
        drawHeartEye(&c, cx: 24.5, cy: 27.3)
        drawHeartEye(&c, cx: 39.5, cy: 27.3)
    case .surprised:
        drawWideEye(&c, cx: 24.5, cy: 27.3)
        drawWideEye(&c, cx: 39.5, cy: 27.3)
    case .closed:
        for bx in [24.5, 39.5] {
            c.plot(bx - 3, 26.5, "k")
            c.plot(bx - 2, 27.6, "k"); c.plot(bx - 1, 28.1, "k")
            c.plot(bx, 28.1, "k"); c.plot(bx + 1, 28.1, "k")
            c.plot(bx + 2, 27.6, "k"); c.plot(bx + 3, 26.5, "k")
        }
    }

    // 鼻子 + 嘴
    c.triangle((30.5, 31.2), (33.5, 31.2), (32, 32.9), "p")
    switch eyes {
    case .happy, .love:
        // 咧嘴笑
        c.plot(30, 34, "k"); c.plot(31, 35, "k"); c.plot(32, 35.3, "k")
        c.plot(33, 35, "k"); c.plot(34, 34, "k")
        c.plot(31.5, 34.3, "p"); c.plot(32.5, 34.3, "p")
    case .surprised:
        c.disc(cx: 32, cy: 34.6, r: 1.9, "k")
        c.disc(cx: 32, cy: 34.6, r: 1.0, "p")
    default:
        c.plot(32, 33.5, "k")
        c.plot(31, 34.4, "k"); c.plot(30, 33.7, "k")
        c.plot(33, 34.4, "k"); c.plot(34, 33.7, "k")
    }

    // 腮红（开心/爱心/惊讶时更明显）
    let blushWide = (eyes == .happy || eyes == .love)
    c.plot(18.5, 32.5, "p"); c.plot(19.5, 32.5, "p")
    c.plot(45.5, 32.5, "p"); c.plot(44.5, 32.5, "p")
    if blushWide {
        c.plot(17.5, 32.5, "p"); c.plot(20.5, 32.5, "p")
        c.plot(46.5, 32.5, "p"); c.plot(43.5, 32.5, "p")
    }

    // 爪子脚趾线
    c.rect(23.9, 59.5, 1, 2.2, "d"); c.rect(26.1, 59.5, 1, 2.2, "d")
    c.rect(37.9, 59.5, 1, 2.2, "d"); c.rect(40.1, 59.5, 1, 2.2, "d")

    // 白色长胡须（最后画，避免被描边加粗）
    c.line(12, 30.5, 17.5, 30, thickness: 1, "w")
    c.line(12, 35, 17.5, 34.5, thickness: 1, "w")
    c.line(52, 30.5, 46.5, 30, thickness: 1, "w")
    c.line(52, 35, 46.5, 34.5, thickness: 1, "w")

    // 白色部位下缘补浅灰阴影
    c.shadeBottom(depth: 1, dark: "h")

    return c.toFrame()
}

// MARK: - 正面伸懒腰（睡醒 → 行走之间的过渡动作）
/// deep = true 时为「完全伸展」那一帧：头压得更低、前爪伸得更远、屁股翘得更高
func buildStretchCat(deep: Bool) -> Frame {
    var c = PixelCanvas()

    let d: Double = deep ? 7 : 4            // 头下压的幅度
    let bodyCy: Double = deep ? 52 : 51     // 身体中心
    let spread: Double = deep ? 4.5 : 1.5   // 前爪向外伸展

    // 高高竖起的尾巴（伸懒腰时屁股翘起，尾巴竖得像天线）
    let tipX = deep ? 52.5 : 55.5
    let tipY = deep ? 20.0 : 26.0
    c.line(46, 50, tipX, tipY, thickness: 5.2, "o")
    c.ellipse(cx: tipX + 0.4, cy: tipY - 1.8, rx: 3.6, ry: 3.6, "o")
    c.ellipse(cx: tipX + 1.2, cy: tipY - 3.4, rx: 2.4, ry: 2.4, "d")

    // 身体：前低后高、拉长的椭圆——带体积光影
    c.shadedEllipse(cx: 32, cy: bodyCy, rx: 20.5, ry: 8.2)
    c.shadedEllipse(cx: 42, cy: bodyCy - 3, rx: 9, ry: 7.5)      // 后臀翘起
    c.ellipse(cx: 32, cy: bodyCy + 3, rx: 9, ry: 4, "w")        // 白胸脯

    // 前腿向前外侧伸直（伸懒腰的标志动作）
    c.line(25, bodyCy - 2, 16 - spread, 57.5, thickness: 5.6, "o")
    c.line(39, bodyCy - 2, 48 + spread, 57.5, thickness: 5.6, "o")
    // 白色前爪
    c.ellipse(cx: 14.5 - spread, cy: 59, rx: 5.2, ry: 3.4, "w")
    c.ellipse(cx: 49.5 + spread, cy: 59, rx: 5.2, ry: 3.4, "w")

    // 头（低头，压在前爪之间）
    let hcy = 26 + d
    c.shadedEllipse(cx: 32, cy: hcy, rx: 17.5, ry: 15.5, rim: 0.78, highlight: 0.42)
    // 腮边绒毛
    c.triangle((15.5, hcy + 3), (10.5, hcy + 6), (15.5, hcy + 9), "o")
    c.triangle((48.5, hcy + 3), (53.5, hcy + 6), (48.5, hcy + 9), "o")
    c.triangle((16, hcy - 2), (12.5, hcy + 0.5), (16, hcy + 3), "o")
    c.triangle((48, hcy - 2), (51.5, hcy + 0.5), (48, hcy + 3), "o")
    // 耳朵（正三角）+ 耳内粉色
    c.triangle((17.5, hcy - 8), (28.5, hcy - 8), (21, hcy - 22), "o")
    c.triangle((35.5, hcy - 8), (46.5, hcy - 8), (43, hcy - 22), "o")
    c.triangle((19.8, hcy - 9.8), (26.2, hcy - 9.8), (22.2, hcy - 18.5), "p")
    c.triangle((37.8, hcy - 9.8), (44.2, hcy - 9.8), (41.8, hcy - 18.5), "p")
    // 额头虎斑
    c.rect(31, hcy - 14.5, 2, 6.5, "d")
    c.rect(26, hcy - 13.2, 2, 5, "d")
    c.rect(36, hcy - 13.2, 2, 5, "d")

    c.addOutline()

    // 白口鼻
    c.ellipse(cx: 32, cy: hcy + 7.5, rx: 6.8, ry: 4.6, "w")

    // 舒服地眯起眼睛
    for bx in [24.5, 39.5] {
        c.plot(bx - 3, hcy + 0.8, "k")
        c.plot(bx - 2, hcy + 1.9, "k"); c.plot(bx - 1, hcy + 2.3, "k")
        c.plot(bx, hcy + 2.3, "k"); c.plot(bx + 1, hcy + 2.3, "k")
        c.plot(bx + 2, hcy + 1.9, "k"); c.plot(bx + 3, hcy + 0.8, "k")
    }

    // 鼻子 + 打哈欠的小嘴
    c.triangle((30.5, hcy + 5.2), (33.5, hcy + 5.2), (32, hcy + 6.9), "p")
    c.disc(cx: 32, cy: hcy + 9.4, r: 1.9, "k")
    c.disc(cx: 32, cy: hcy + 9.8, r: 1.0, "p")

    // 腮红
    c.plot(18.5, hcy + 6.5, "p"); c.plot(19.5, hcy + 6.5, "p")
    c.plot(45.5, hcy + 6.5, "p"); c.plot(44.5, hcy + 6.5, "p")

    // 前爪脚趾线
    c.rect(13.4 - spread, 60.2, 1, 2, "d"); c.rect(15.6 - spread, 60.2, 1, 2, "d")
    c.rect(48.4 + spread, 60.2, 1, 2, "d"); c.rect(50.6 + spread, 60.2, 1, 2, "d")

    // 白色长胡须
    c.line(12, hcy + 4.5, 17.5, hcy + 4, thickness: 1, "w")
    c.line(12, hcy + 9, 17.5, hcy + 8.5, thickness: 1, "w")
    c.line(52, hcy + 4.5, 46.5, hcy + 4, thickness: 1, "w")
    c.line(52, hcy + 9, 46.5, hcy + 8.5, thickness: 1, "w")

    // 白色部位下缘补浅灰阴影
    c.shadeBottom(depth: 1, dark: "h")

    return c.toFrame()
}

// 琥珀色大眼（gaze: 瞳孔左右偏移，表现「看向某侧」，-1 看左 / +1 看右）
private func drawBigEye(_ c: inout PixelCanvas, cx: Double, cy: Double, gaze: Double = 0) {
    c.ellipse(cx: cx, cy: cy, rx: 3.7, ry: 4.2, "k")
    c.ellipse(cx: cx + gaze * 0.9, cy: cy, rx: 3.0, ry: 3.5, "g")
    c.ellipse(cx: cx + gaze, cy: cy + 0.8, rx: 1.2, ry: 2.3, "k")
    c.plot(cx - 1.3 + gaze * 0.9, cy - 1.9, "w"); c.plot(cx - 0.3 + gaze * 0.9, cy - 1.9, "w")
}

// 瞪圆的眼睛
private func drawWideEye(_ c: inout PixelCanvas, cx: Double, cy: Double) {
    c.ellipse(cx: cx, cy: cy, rx: 4.3, ry: 4.8, "k")
    c.ellipse(cx: cx, cy: cy, rx: 3.5, ry: 4.0, "g")
    c.ellipse(cx: cx, cy: cy + 0.6, rx: 1.6, ry: 2.6, "k")
    c.plot(cx - 1.6, cy - 2.2, "w"); c.plot(cx - 0.6, cy - 2.2, "w")
}

// 爱心眼
private func drawHeartEye(_ c: inout PixelCanvas, cx: Double, cy: Double) {
    let pts: [(Double, Double)] = [
        (-1, -2), (1, -2),
        (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1),
        (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0),
        (-1, 1), (0, 1), (1, 1),
        (0, 2),
    ]
    for p in pts { c.plot(cx + p.0, cy + p.1, "p") }
    c.plot(cx - 1, cy - 1, "w")
}

// MARK: - 侧面行走小猫（4 帧步态循环，朝右）
/// 身体由「前胸 + 腰腹 + 后臀」三段椭圆拼出自然曲线，四条腿带膝弯、有抬脚与落地的差别
private func sideLeg(_ c: inout PixelCanvas, hipX: Double, swing: Double, dy: Double,
                     width: Double, color: Character, paw: Character) {
    let hipY = 44.0 + dy
    let dx = sin(swing) * 4.8
    let lift = max(0, cos(swing)) * 2.6
    let footX = hipX + dx
    let footY = 59.0 - lift
    let kneeX = hipX + dx * 0.45 + (dx > 0 ? -1.0 : 1.0)   // 膝盖反向前折
    let kneeY = (hipY + footY) / 2

    c.line(hipX, hipY, kneeX, kneeY, thickness: width, color)
    c.line(kneeX, kneeY, footX, footY, thickness: width * 0.88, color)
    c.ellipse(cx: footX, cy: footY + 0.8, rx: width * 0.66, ry: width * 0.5, paw)
}

func buildWalkCat(phase: Int, eyes: Expression = .normal) -> Frame {
    var c = PixelCanvas()

    let theta = Double(phase) / 4.0 * 2 * .pi
    let bodyDy: Double = phase % 2 == 0 ? -0.6 : 0.4      // 身体起伏
    let headDy: Double = phase % 2 == 0 ? -0.5 : 0.5      // 头部点动

    // 大尾巴（先画，在身体后方；随步伐上下摆）
    // 尾根贴在臀部上后方（x≈12.5, y≈36.5），不会从腰侧穿出来
    if phase % 2 == 0 {
        c.ellipse(cx: 12.5, cy: 37.5 + bodyDy, rx: 3.6, ry: 3.4, "o")     // 尾根过渡
        c.line(12.5, 37 + bodyDy, 3.8, 22.5, thickness: 5.0, "o")
        c.ellipse(cx: 3.4, cy: 21, rx: 3.5, ry: 3.5, "o")
        c.ellipse(cx: 3.0, cy: 19.9, rx: 2.4, ry: 2.4, "d")
    } else {
        c.ellipse(cx: 12.5, cy: 38 + bodyDy, rx: 3.6, ry: 3.4, "o")
        c.line(12.5, 37.5 + bodyDy, 3.0, 29.5, thickness: 5.0, "o")
        c.ellipse(cx: 2.6, cy: 28.5, rx: 3.5, ry: 3.5, "o")
        c.ellipse(cx: 2.2, cy: 27.4, rx: 2.4, ry: 2.4, "d")
    }

    // 远侧两条腿（深色，压在身体后面，对角步态）
    sideLeg(&c, hipX: 38.0, swing: theta + .pi, dy: bodyDy, width: 4.4, color: "d", paw: "h")
    sideLeg(&c, hipX: 13.5, swing: theta, dy: bodyDy, width: 4.4, color: "d", paw: "h")

    // 身体：前胸 + 腰腹 + 后臀，三段拼出猫的背线弧度
    c.ellipse(cx: 27, cy: 46.5 + bodyDy, rx: 16.5, ry: 10, "o")
    c.ellipse(cx: 38, cy: 45 + bodyDy, rx: 9.5, ry: 9.5, "o")
    c.ellipse(cx: 15, cy: 46 + bodyDy, rx: 10, ry: 10, "o")

    // 白胸口 + 白肚皮
    c.ellipse(cx: 40.5, cy: 50 + bodyDy, rx: 6.2, ry: 4.8, "w")
    c.ellipse(cx: 25, cy: 52.5 + bodyDy, rx: 11.5, ry: 4.4, "w")

    // 背部虎斑纹（顺脊背排列）
    c.rect(18, 36.5 + bodyDy, 2.6, 4.2, "d")
    c.rect(24, 35.8 + bodyDy, 2.6, 4.2, "d")
    c.rect(30, 36.2 + bodyDy, 2.4, 4.0, "d")
    c.rect(34.5, 37.2 + bodyDy, 2.0, 3.6, "d")

    // 近侧两条腿（亮色，压在身体前面）
    sideLeg(&c, hipX: 41.5, swing: theta, dy: bodyDy, width: 4.8, color: "o", paw: "w")
    sideLeg(&c, hipX: 16.5, swing: theta + .pi, dy: bodyDy, width: 4.8, color: "o", paw: "w")

    // 头 + 脖子
    let hy = 29.5 + headDy
    c.ellipse(cx: 39.5, cy: hy + 9, rx: 7.5, ry: 6.5, "o")        // 脖子到肩的过渡
    c.ellipse(cx: 46.5, cy: hy, rx: 13.5, ry: 12.5, "o")          // 大圆头
    // 腮边绒毛（后脑一侧）
    c.triangle((34.5, hy - 2), (30.5, hy + 1), (34.5, hy + 4), "o")
    c.triangle((35.5, hy + 6), (31.5, hy + 8.5), (35.5, hy + 11), "o")
    // 耳朵（正三角，尖端朝上）+ 耳内粉色
    c.triangle((36.5, hy - 8.5), (45.5, hy - 8.5), (40.2, hy - 21.5), "o")
    c.triangle((46.5, hy - 9), (54.5, hy - 9), (50.4, hy - 23), "o")
    c.triangle((48.6, hy - 10.5), (52.6, hy - 10.5), (50.5, hy - 19), "p")
    // 额头虎斑
    c.rect(38.5, hy - 8.5, 2, 4, "d")
    c.rect(42.2, hy - 9.5, 2, 4, "d")

    // 整体体积光影（多块形状拼合也不会出现内部接缝）
    c.shadeSilhouette()

    // 自动描边
    c.addOutline()

    // 白色口鼻
    c.ellipse(cx: 55.5, cy: hy + 5.5, rx: 5.2, ry: 4.4, "w")

    // 眼睛（侧面单眼，可带表情）
    switch eyes {
    case .closed:
        c.plot(48.6, hy - 1.2, "k")
        c.plot(49.6, hy - 0.2, "k"); c.plot(50.5, hy + 0.2, "k")
        c.plot(51.5, hy - 0.2, "k"); c.plot(52.4, hy - 1.2, "k")
    case .happy:
        c.plot(48.4, hy - 0.4, "k"); c.plot(49.4, hy - 1.6, "k")
        c.plot(50.5, hy - 2.0, "k")
        c.plot(51.6, hy - 1.6, "k"); c.plot(52.6, hy - 0.4, "k")
    case .love:
        drawHeartEye(&c, cx: 50.5, cy: hy - 1.5)
    case .surprised:
        drawWideEye(&c, cx: 50.5, cy: hy - 1.5)
    case .normal:
        c.ellipse(cx: 50.5, cy: hy - 1.5, rx: 3.4, ry: 4, "k")
        c.ellipse(cx: 50.5, cy: hy - 1.5, rx: 2.7, ry: 3.3, "g")
        c.ellipse(cx: 50.5, cy: hy - 0.8, rx: 1.1, ry: 2.2, "k")
        c.plot(49.3, hy - 3.4, "w"); c.plot(50.3, hy - 3.4, "w")
    }

    // 粉鼻子 + 小嘴（开心时咧嘴）
    c.triangle((57.4, hy + 3.2), (59.8, hy + 3.2), (58.6, hy + 4.9), "p")
    if eyes == .happy || eyes == .love {
        c.plot(57.2, hy + 6.2, "k"); c.plot(58.2, hy + 6.8, "k"); c.plot(59.2, hy + 6.2, "k")
    } else {
        c.plot(58, hy + 5.6, "k"); c.plot(57, hy + 6.4, "k")
    }

    // 胡须
    c.line(59.5, hy + 2.5, 63.5, hy + 1.6, thickness: 1, "k")
    c.line(59.5, hy + 7, 63.5, hy + 7.6, thickness: 1, "k")

    // 白色部位下缘补浅灰阴影
    c.shadeBottom(depth: 1, dark: "h")

    return c.toFrame()
}

// MARK: - 三四分之一侧身（行走 ↔ 坐下 的过渡姿态）
/// lift: 0 = 后腿收拢、重心下沉（即将坐下）；1 = 四肢直立（刚站起来）
/// tailDown / tailFlip: 尾巴贴地扫地（两个扫动方向）；headTurn: -1 看左 / 0 正面 / +1 看右
func buildQuarterCat(lift: Double, eyes: Expression = .normal,
                     tailDown: Bool = false, tailFlip: Bool = false,
                     headTurn: Double = 0) -> Frame {
    var c = PixelCanvas()
    let stand = max(0, min(1, lift))

    let bodyCy = 50.5 - stand * 7.5          // 站起来时身体抬高
    let bodyRx = 16.5 - stand * 2.2          // 站立时身形收窄
    let bodyRy = 8.2 + stand * 3.6           // 站立时更高
    let headCy = 30 - stand * 3.0
    let hx = 31 + headTurn * 2.0             // 头部整体偏移
    let fx = hx + headTurn * 1.6             // 五官偏移更多，形成转头感

    // 尾巴
    if tailDown {
        // 贴地扫尾（坐下时扫两下地面）
        let tipX = tailFlip ? 59.0 : 52.0
        let tipY = tailFlip ? 58.6 : 56.6
        c.ellipse(cx: 45.5, cy: bodyCy + 3, rx: 3.6, ry: 3.2, "o")
        c.line(45.5, bodyCy + 3, tipX - 1.6, tipY - 1.2, thickness: 4.8, "o")
        c.ellipse(cx: tipX, cy: tipY, rx: 3.2, ry: 2.7, "o")
        c.ellipse(cx: tipX + (tailFlip ? 0.8 : -0.8), cy: tipY - 0.3, rx: 2.1, ry: 1.8, "d")
    } else {
        // 尾巴从右后臀向上翘，尾尖深色
        c.ellipse(cx: 46, cy: bodyCy - 2, rx: 3.6, ry: 3.4, "o")
        c.line(46, bodyCy - 3, 56.5, bodyCy - 13, thickness: 5.0, "o")
        c.ellipse(cx: 57.2, cy: bodyCy - 14.5, rx: 3.5, ry: 3.5, "o")
        c.ellipse(cx: 58.0, cy: bodyCy - 15.6, rx: 2.4, ry: 2.4, "d")
    }

    // 后臀（右后方更鼓，坐下时更明显）
    c.ellipse(cx: 43, cy: bodyCy + 1, rx: 11.5, ry: bodyRy * 0.92, "o")
    // 身体
    c.ellipse(cx: 30, cy: bodyCy, rx: bodyRx, ry: bodyRy, "o")
    // 白胸脯
    c.ellipse(cx: 31, cy: bodyCy + bodyRy * 0.42, rx: 7.4, ry: bodyRy * 0.5, "w")

    // 前腿（站立时露出来，坐下时几乎收进身体）
    let legTop = bodyCy + bodyRy * 0.40
    let legLen = max(2.6, 59.5 - legTop)
    for lx in [21.5, 36.0] {
        c.rect(lx, legTop, 4.8, legLen, "o")
        c.ellipse(cx: lx + 2.4, cy: legTop + legLen - 1.0, rx: 3.3, ry: 2.4, "w")
    }
    // 后爪（从臀侧露出一点）
    c.ellipse(cx: 47.5, cy: bodyCy + bodyRy * 0.68, rx: 4.4, ry: 2.8, "w")

    // 头（正面，可左右转）
    c.ellipse(cx: hx, cy: headCy, rx: 16.5, ry: 15, "o")
    // 腮边绒毛
    c.triangle((hx - 16, headCy + 3), (hx - 21, headCy + 6), (hx - 16, headCy + 9), "o")
    c.triangle((hx + 16, headCy + 3), (hx + 21, headCy + 6), (hx + 16, headCy + 9), "o")
    c.triangle((hx - 15.5, headCy - 2), (hx - 19, headCy + 0.5), (hx - 15.5, headCy + 3), "o")
    c.triangle((hx + 15.5, headCy - 2), (hx + 19, headCy + 0.5), (hx + 15.5, headCy + 3), "o")
    // 耳朵（正三角）+ 耳内粉色
    c.triangle((hx - 14.5, headCy - 8), (hx - 3.5, headCy - 8), (hx - 11, headCy - 22), "o")
    c.triangle((hx + 3.5, headCy - 8), (hx + 14.5, headCy - 8), (hx + 11, headCy - 22), "o")
    c.triangle((hx - 12.2, headCy - 9.8), (hx - 5.8, headCy - 9.8), (hx - 9.8, headCy - 18.5), "p")
    c.triangle((hx + 5.8, headCy - 9.8), (hx + 12.2, headCy - 9.8), (hx + 9.8, headCy - 18.5), "p")
    // 额头虎斑
    c.rect(hx - 1, headCy - 14.5, 2, 6.5, "d")
    c.rect(hx - 6, headCy - 13.2, 2, 5, "d")
    c.rect(hx + 4, headCy - 13.2, 2, 5, "d")

    c.shadeSilhouette()
    c.addOutline()

    // 白口鼻
    let mx = hx + headTurn * 0.8
    c.ellipse(cx: mx, cy: headCy + 7.5, rx: 6.8, ry: 4.6, "w")

    // 表情（过渡姿态也带表情，摸猫时能看到爱心眼）
    switch eyes {
    case .normal:
        drawBigEye(&c, cx: fx - 7.5, cy: headCy + 1.3, gaze: headTurn * 0.9)
        drawBigEye(&c, cx: fx + 7.5, cy: headCy + 1.3, gaze: headTurn * 0.9)
    case .happy:
        for bx in [fx - 7.5, fx + 7.5] {
            c.plot(bx - 3, headCy + 2.5, "k"); c.plot(bx - 2, headCy + 1.3, "k")
            c.plot(bx - 1, headCy + 0.5, "k"); c.plot(bx, headCy + 0.2, "k")
            c.plot(bx + 1, headCy + 0.5, "k"); c.plot(bx + 2, headCy + 1.3, "k")
            c.plot(bx + 3, headCy + 2.5, "k")
        }
    case .love:
        drawHeartEye(&c, cx: fx - 7.5, cy: headCy + 1.3)
        drawHeartEye(&c, cx: fx + 7.5, cy: headCy + 1.3)
    case .surprised:
        drawWideEye(&c, cx: fx - 7.5, cy: headCy + 1.3)
        drawWideEye(&c, cx: fx + 7.5, cy: headCy + 1.3)
    case .closed:
        for bx in [fx - 7.5, fx + 7.5] {
            c.plot(bx - 3, headCy + 0.3, "k")
            c.plot(bx - 2, headCy + 1.4, "k"); c.plot(bx - 1, headCy + 1.9, "k")
            c.plot(bx, headCy + 1.9, "k"); c.plot(bx + 1, headCy + 1.9, "k")
            c.plot(bx + 2, headCy + 1.4, "k"); c.plot(bx + 3, headCy + 0.3, "k")
        }
    }

    // 鼻子 + 嘴
    c.triangle((mx - 1.5, headCy + 5.2), (mx + 1.5, headCy + 5.2), (mx, headCy + 6.9), "p")
    switch eyes {
    case .happy, .love:
        // 咧嘴笑
        c.plot(mx - 2, headCy + 8, "k"); c.plot(mx - 1, headCy + 9, "k"); c.plot(mx, headCy + 9.3, "k")
        c.plot(mx + 1, headCy + 9, "k"); c.plot(mx + 2, headCy + 8, "k")
        c.plot(mx - 0.5, headCy + 8.3, "p"); c.plot(mx + 0.5, headCy + 8.3, "p")
    case .surprised:
        c.disc(cx: mx, cy: headCy + 8.6, r: 1.9, "k")
        c.disc(cx: mx, cy: headCy + 8.6, r: 1.0, "p")
    default:
        c.plot(mx, headCy + 7.5, "k")
        c.plot(mx - 1, headCy + 8.4, "k"); c.plot(mx - 2, headCy + 7.7, "k")
        c.plot(mx + 1, headCy + 8.4, "k"); c.plot(mx + 2, headCy + 7.7, "k")
    }

    // 腮红（开心/爱心时更明显）
    let wide = (eyes == .happy || eyes == .love)
    c.plot(hx - 13.5, headCy + 6.5, "p"); c.plot(hx - 12.5, headCy + 6.5, "p")
    c.plot(hx + 13.5, headCy + 6.5, "p"); c.plot(hx + 12.5, headCy + 6.5, "p")
    if wide {
        c.plot(hx - 14.5, headCy + 6.5, "p"); c.plot(hx - 11.5, headCy + 6.5, "p")
        c.plot(hx + 14.5, headCy + 6.5, "p"); c.plot(hx + 11.5, headCy + 6.5, "p")
    }

    // 前爪脚趾线
    c.rect(22.9, 56.5, 1, 2, "d"); c.rect(25.1, 56.5, 1, 2, "d")
    c.rect(37.4, 56.5, 1, 2, "d"); c.rect(39.6, 56.5, 1, 2, "d")

    // 胡须（跟着头一起转）
    c.line(hx - 20, headCy + 4.5, hx - 14.5, headCy + 4, thickness: 1, "w")
    c.line(hx - 20, headCy + 9, hx - 14.5, headCy + 8.5, thickness: 1, "w")
    c.line(hx + 20, headCy + 4.5, hx + 14.5, headCy + 4, thickness: 1, "w")
    c.line(hx + 20, headCy + 9, hx + 14.5, headCy + 8.5, thickness: 1, "w")

    c.shadeBottom(depth: 1, dark: "h")

    return c.toFrame()
}

// MARK: - 舔爪子（坐下前的清洁小动作）
/// 蹲坐着把右前爪抬到嘴边，低头眯眼舔爪垫
/// frame 0→3 组成一个舔舐循环：探头贴爪舔 → 半抬头 → 抬头咽口水 → 再低头
/// 头部画成独立图层，绕脖颈支点做真实的旋转，所以能看出「头跟着嘴转」
func buildLickCat(frame: Int, eyes: Expression = .closed) -> Frame {
    var c = PixelCanvas()

    // 舔舐节奏：headAngle 正 = 顺时针（口鼻朝爪子压下去），负 = 抬起来
    let k = min(max(frame, 0), 3)
    let headAngle = [13.0, 8.0, -6.0, 9.0][k]
    let tongue = [1.0, 0.5, 0.0, 0.3][k]
    let pivot = (30.0, 46.5)                            // 脖颈支点

    // ——— 身体层 ———
    // 尾巴：从右后臀贴地绕到身前
    c.ellipse(cx: 47.5, cy: 52.6, rx: 3.8, ry: 3.4, "o")
    c.line(47.5, 52.6, 55.4, 58.2, thickness: 4.8, "o")
    c.ellipse(cx: 56.4, cy: 58.8, rx: 3.2, ry: 2.6, "o")
    c.ellipse(cx: 57.4, cy: 58.5, rx: 2.1, ry: 1.7, "d")

    // 后臀 + 身体（蹲坐，重心压低）
    c.ellipse(cx: 43, cy: 53.6, rx: 11.4, ry: 8.4, "o")
    c.ellipse(cx: 30, cy: 52.6, rx: 15.0, ry: 9.0, "o")
    c.ellipse(cx: 30, cy: 55.8, rx: 7.6, ry: 5.0, "w")   // 白胸脯

    // 撑地的左前腿
    c.rect(18.6, 52.6, 5.0, 8.4, "o")
    c.ellipse(cx: 21.1, cy: 60.2, rx: 3.4, ry: 2.3, "w")

    // 抬起的右前腿（透视压缩：前臂贴着胸口竖起来，爪垫凑到下巴边上）
    c.line(42.8, 53.4, 41.6, 46.0, thickness: 5.2, "o")
    c.ellipse(cx: 40.6, cy: 43.2, rx: 4.0, ry: 3.2, "w")

    // 身体层光影 + 描边（之前只给头层描边，身体边缘是毛边没线）
    c.shadeSilhouette()
    c.addOutline()

    // ——— 头部层（整体旋转后合成）———
    var h = PixelCanvas()
    let hx = 29.5
    let headCy = 31.5
    let mx = hx + 6.2                                   // 口鼻偏向抬起的爪子

    h.ellipse(cx: hx, cy: headCy, rx: 15.6, ry: 14.2, "o")
    // 腮边绒毛
    h.triangle((hx - 15, headCy + 3), (hx - 20, headCy + 6), (hx - 15, headCy + 9), "o")
    h.triangle((hx + 15, headCy + 3), (hx + 20, headCy + 6), (hx + 15, headCy + 9), "o")
    h.triangle((hx - 14.5, headCy - 2), (hx - 18, headCy + 0.5), (hx - 14.5, headCy + 3), "o")
    h.triangle((hx + 14.5, headCy - 2), (hx + 18, headCy + 0.5), (hx + 14.5, headCy + 3), "o")
    // 耳朵（正三角）+ 耳内粉色
    h.triangle((hx - 13.5, headCy - 8), (hx - 2.5, headCy - 8), (hx - 10, headCy - 22), "o")
    h.triangle((hx + 2.5, headCy - 8), (hx + 13.5, headCy - 8), (hx + 10, headCy - 22), "o")
    h.triangle((hx - 11.2, headCy - 9.8), (hx - 4.8, headCy - 9.8), (hx - 8.8, headCy - 18.5), "p")
    h.triangle((hx + 4.8, headCy - 9.8), (hx + 11.2, headCy - 9.8), (hx + 8.8, headCy - 18.5), "p")
    // 额头虎斑
    h.rect(hx - 1, headCy - 14.5, 2, 6.5, "d")
    h.rect(hx - 6, headCy - 13.2, 2, 5, "d")
    h.rect(hx + 4, headCy - 13.2, 2, 5, "d")
    // 脖子：往下多画一截，旋转时不会在肩膀处露出豁口
    // 脖子这截是「埋进身体里」的，不能描边，否则旋转合成后会在身上出现一道黑线
    let beforeNeck = h.cells
    h.ellipse(cx: hx + 1, cy: headCy + 13.5, rx: 9.5, ry: 5.0, "o")
    let afterNeck = h.cells
    var neckCells = Set<Int>()
    for ny in 0..<GRID_H {
        for nx in 0..<GRID_W where afterNeck[ny][nx] != "." && beforeNeck[ny][nx] == "." {
            neckCells.insert(ny * GRID_W + nx)
        }
    }

    h.shadeSilhouette()
    h.addOutline(skip: { x, y in
        [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { dx, dy in
            let nx = x + dx, ny = y + dy
            return nx >= 0 && nx < GRID_W && ny >= 0 && ny < GRID_H
                && neckCells.contains(ny * GRID_W + nx)
        }
    })

    // 白口鼻
    h.ellipse(cx: mx, cy: headCy + 6.4, rx: 6.4, ry: 4.4, "w")

    // 眼睛（低头舔爪时放松地眯着）
    switch eyes {
    case .normal:
        drawBigEye(&h, cx: hx - 8, cy: headCy + 0.6, gaze: 0.8)
        drawBigEye(&h, cx: hx + 6, cy: headCy + 0.8, gaze: 0.8)
    case .happy:
        for bx in [hx - 8, hx + 6] {
            h.plot(bx - 3, headCy + 2.2, "k"); h.plot(bx - 2, headCy + 1.0, "k")
            h.plot(bx - 1, headCy + 0.2, "k"); h.plot(bx, headCy - 0.1, "k")
            h.plot(bx + 1, headCy + 0.2, "k"); h.plot(bx + 2, headCy + 1.0, "k")
            h.plot(bx + 3, headCy + 2.2, "k")
        }
    case .love:
        drawHeartEye(&h, cx: hx - 8, cy: headCy + 0.6)
        drawHeartEye(&h, cx: hx + 6, cy: headCy + 0.8)
    case .surprised:
        drawWideEye(&h, cx: hx - 8, cy: headCy + 0.6)
        drawWideEye(&h, cx: hx + 6, cy: headCy + 0.8)
    case .closed:
        for bx in [hx - 8, hx + 6] {
            h.plot(bx - 3, headCy + 0.1, "k")
            h.plot(bx - 2, headCy + 1.2, "k"); h.plot(bx - 1, headCy + 1.7, "k")
            h.plot(bx, headCy + 1.7, "k"); h.plot(bx + 1, headCy + 1.7, "k")
            h.plot(bx + 2, headCy + 1.2, "k"); h.plot(bx + 3, headCy + 0.1, "k")
        }
    }

    // 粉鼻子
    h.triangle((mx - 1.5, headCy + 4.4), (mx + 1.5, headCy + 4.4), (mx, headCy + 6.0), "p")

    // 舌头：从嘴里朝爪垫伸过去（伸出程度 = tongue，收回时只留一个粉色小口）
    let tsx = mx + 0.4, tsy = headCy + 7.0
    if tongue > 0.05 {
        let tex = tsx + (40.4 - tsx) * tongue
        let tey = tsy + (41.6 - tsy) * tongue
        h.line(tsx, tsy, tex, tey, thickness: 2.2 + tongue * 0.5, "p")
        h.ellipse(cx: tex + 0.2, cy: tey + 0.2,
                 rx: 1.3 + tongue * 0.8, ry: 1.0 + tongue * 0.4, "p")
    } else {
        h.ellipse(cx: mx, cy: headCy + 7.0, rx: 1.7, ry: 1.1, "p")
    }

    // 胡须
    h.line(hx - 20, headCy + 4.5, hx - 14.5, headCy + 4, thickness: 1, "w")
    h.line(hx - 20, headCy + 9, hx - 14.5, headCy + 8.5, thickness: 1, "w")
    h.line(hx + 20, headCy + 4.5, hx + 14.5, headCy + 4, thickness: 1, "w")
    h.line(hx + 20, headCy + 9, hx + 14.5, headCy + 8.5, thickness: 1, "w")

    // 头部整体绕脖子旋转后贴到身体上
    c.compositeRotated(h.cells, degrees: headAngle, pivot: pivot)

    // 爪垫下缘的脚趾缝（浅色，避免像破洞）
    c.rect(39.2, 44.6, 1, 1.6, "h")
    c.rect(41.0, 44.6, 1, 1.6, "h")

    c.shadeBottom(depth: 1, dark: "h")

    return c.toFrame()
}

// MARK: - 所有姿势帧
// 命名规则：<姿态> 或 <姿态>_<表情>，表情后缀为空即普通
// 例：walk1_love、quarterStand_happy、sitA（普通）
let expressionSuffixes: [(String, Expression)] = [
    ("", .normal),
    ("_happy", .happy),
    ("_love", .love),
    ("_closed", .closed),
    ("_surprise", .surprised),
]

// 正面趴卧系（含尾巴两向摆动）
let poseFrames: [String: Frame] = {
    var all: [String: Frame] = [
    "sitA": buildSitCat(eyes: .normal, tailUp: true),
    "sitB": buildSitCat(eyes: .normal, tailUp: false),
    "happyA": buildSitCat(eyes: .happy, tailUp: true),
    "happyB": buildSitCat(eyes: .happy, tailUp: false),
    "loveA": buildSitCat(eyes: .love, tailUp: true),
    "loveB": buildSitCat(eyes: .love, tailUp: false),
    "surpriseA": buildSitCat(eyes: .surprised, tailUp: true),
    "surpriseB": buildSitCat(eyes: .surprised, tailUp: false),
    "sleepA": buildSitCat(eyes: .closed, tailUp: true),
    "sleepB": buildSitCat(eyes: .closed, tailUp: false),
    // 伸懒腰（睡醒 → 行走的过渡）
    "stretchA": buildStretchCat(deep: false),
    "stretchB": buildStretchCat(deep: true),
    // 舔爪子（坐下前的清洁动作，4 帧一个舔舐循环）
    "lickA": buildLickCat(frame: 0),
    "lickB": buildLickCat(frame: 1),
    "lickC": buildLickCat(frame: 2),
    "lickD": buildLickCat(frame: 3),
    ]

    // 行走 4 相位 × 表情
    for ph in 0..<4 {
        for (suffix, eyes) in expressionSuffixes {
            all["walk\(ph)\(suffix)"] = buildWalkCat(phase: ph, eyes: eyes)
        }
    }

    // 三四分之一侧身过渡姿态 × 表情
    let quarterPoses: [(String, (Expression) -> Frame)] = [
        ("quarterStand", { buildQuarterCat(lift: 1.0, eyes: $0) }),                                   // 四肢直立
        ("quarterRise", { buildQuarterCat(lift: 0.72, eyes: $0) }),                                   // 半起身（过渡中间帧）
        ("quarterCrouch", { buildQuarterCat(lift: 0.35, eyes: $0) }),                                 // 收腿下沉
        ("quarterLow", { buildQuarterCat(lift: 0.15, eyes: $0) }),                                    // 几乎坐实（过渡中间帧）
        ("quarterSweepA", { buildQuarterCat(lift: 0.22, eyes: $0, tailDown: true, tailFlip: false) }), // 尾巴扫地（左）
        ("quarterSweepB", { buildQuarterCat(lift: 0.22, eyes: $0, tailDown: true, tailFlip: true) }),  // 尾巴扫地（右）
        ("lookL", { buildQuarterCat(lift: 1.0, eyes: $0, headTurn: -1) }),                             // 站起来后看左
        ("lookR", { buildQuarterCat(lift: 1.0, eyes: $0, headTurn: 1) }),                              // 看右
    ]
    for (name, make) in quarterPoses {
        for (suffix, eyes) in expressionSuffixes {
            all[name + suffix] = make(eyes)
        }
    }
    return all
}()

// MARK: - 水平镜像（朝左）
func mirrored(_ frame: Frame) -> Frame {
    return frame.map { String($0.reversed()) }
}

// MARK: - 配色（毛色变种）
struct Palette {
    let name: String
    let colors: [Character: NSColor]
}

let petPalettes: [Palette] = [
    Palette(name: "灰虎斑猫", colors: [
        "k": NSColor(srgbRed: 0.17, green: 0.15, blue: 0.16, alpha: 1),
        "o": NSColor(srgbRed: 0.63, green: 0.62, blue: 0.65, alpha: 1),
        "d": NSColor(srgbRed: 0.38, green: 0.36, blue: 0.40, alpha: 1),
        "s": NSColor(srgbRed: 0.45, green: 0.44, blue: 0.48, alpha: 1),   // 体积暗部
        "l": NSColor(srgbRed: 0.76, green: 0.75, blue: 0.78, alpha: 1),   // 受光高光
        "w": NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1),
        "h": NSColor(srgbRed: 0.87, green: 0.86, blue: 0.85, alpha: 1),   // 白色阴影
        "p": NSColor(srgbRed: 0.95, green: 0.62, blue: 0.68, alpha: 1),
        "g": NSColor(srgbRed: 0.92, green: 0.62, blue: 0.14, alpha: 1),   // 琥珀色大眼
    ]),
    Palette(name: "橘猫", colors: [
        "k": NSColor(srgbRed: 0.24, green: 0.14, blue: 0.06, alpha: 1),
        "o": NSColor(srgbRed: 0.96, green: 0.63, blue: 0.26, alpha: 1),
        "d": NSColor(srgbRed: 0.82, green: 0.46, blue: 0.15, alpha: 1),
        "s": NSColor(srgbRed: 0.80, green: 0.47, blue: 0.14, alpha: 1),
        "l": NSColor(srgbRed: 1.00, green: 0.76, blue: 0.44, alpha: 1),
        "w": NSColor(srgbRed: 1.00, green: 0.96, blue: 0.90, alpha: 1),
        "h": NSColor(srgbRed: 0.94, green: 0.89, blue: 0.80, alpha: 1),
        "p": NSColor(srgbRed: 0.98, green: 0.62, blue: 0.68, alpha: 1),
        "g": NSColor(srgbRed: 0.90, green: 0.58, blue: 0.12, alpha: 1),
    ]),
    Palette(name: "黑猫", colors: [
        "k": NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1),
        "o": NSColor(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: 1),
        "d": NSColor(srgbRed: 0.18, green: 0.18, blue: 0.22, alpha: 1),
        "s": NSColor(srgbRed: 0.20, green: 0.20, blue: 0.24, alpha: 1),
        "l": NSColor(srgbRed: 0.45, green: 0.45, blue: 0.51, alpha: 1),
        "w": NSColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1),
        "h": NSColor(srgbRed: 0.70, green: 0.70, blue: 0.74, alpha: 1),
        "p": NSColor(srgbRed: 0.85, green: 0.50, blue: 0.58, alpha: 1),
        "g": NSColor(srgbRed: 0.95, green: 0.75, blue: 0.20, alpha: 1),
    ]),
]

// MARK: - 渲染像素帧为 CGImage（1 位图像素 = 1 个艺术像素）
/// 生成原始分辨率的 CGImage，交给绘制端按「整数个物理像素」放大，
/// 这样任何缩放下每个艺术像素都是等宽等高的一方块，不会出现分格/粗细不一。
func makeCGImage(_ frame: Frame, palette: [Character: NSColor]) -> CGImage? {
    let h = frame.count
    let w = frame.first?.count ?? 0
    guard w > 0, h > 0 else { return nil }

    // 调色板预先解析成 RGBA 字节，避免逐格做颜色空间转换
    var table: [Character: (UInt8, UInt8, UInt8, UInt8)] = [:]
    for (ch, color) in palette {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        table[ch] = (UInt8((r * 255).rounded()), UInt8((g * 255).rounded()),
                     UInt8((b * 255).rounded()), UInt8((a * 255).rounded()))
    }

    var buf = [UInt8](repeating: 0, count: w * h * 4)
    for (row, line) in frame.enumerated() {
        for (col, ch) in line.enumerated() where col < w {
            guard let c = table[ch] else { continue }
            let i = (row * w + col) * 4
            buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2; buf[i + 3] = c.3
        }
    }

    guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

// MARK: - 渲染像素帧为 NSImage
func makeImage(_ frame: Frame, palette: [Character: NSColor], pixel: CGFloat) -> NSImage {
    let h = frame.count
    let w = frame.first?.count ?? 0
    let size = NSSize(width: CGFloat(w) * pixel, height: CGFloat(h) * pixel)
    let img = NSImage(size: size)
    img.lockFocus()
    for (row, line) in frame.enumerated() {
        for (col, ch) in line.enumerated() {
            guard let color = palette[ch] else { continue }
            color.setFill()
            NSRect(x: CGFloat(col) * pixel,
                   y: CGFloat(h - 1 - row) * pixel,
                   width: pixel, height: pixel).fill()
        }
    }
    img.unlockFocus()
    return img
}
