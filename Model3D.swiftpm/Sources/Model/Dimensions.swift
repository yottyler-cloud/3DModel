import SwiftUI

/// スケッチの寸法の種類
enum DimKind: Codable, Hashable {
    /// 長方形の幅・高さ
    case width, height
    /// 円の直径
    case diameter
    /// 多角形の辺 k の長さ
    case edge(Int)
    /// 中心線の長さ
    case length

    var title: String {
        switch self {
        case .width: return "幅"
        case .height: return "高さ"
        case .diameter: return "直径"
        case .edge, .length: return "長さ"
        }
    }
}

/// スケッチに残す寸法。値を変えると図形が変わる(寸法が形を決める)
struct SketchDimension: Codable, Identifiable, Hashable {
    var id = UUID()
    var shapeID: UUID
    var kind: DimKind
    var value: Double
}

enum DimensionMath {
    /// いまの図形から測った値
    static func measure(_ kind: DimKind, _ shape: SketchShape) -> Double? {
        switch (kind, shape.kind) {
        case (.width, .rectangle): return shape.rectSize.x
        case (.height, .rectangle): return shape.rectSize.y
        case (.diameter, .circle): return shape.radius * 2
        case (.length, .centerline): return shape.points[0].distance(to: shape.points[1])
        case (.edge(let k), .polygon):
            guard k >= 0, k < shape.points.count else { return nil }
            return shape.points[k].distance(to: shape.points[(k + 1) % shape.points.count])
        default: return nil
        }
    }

    /// 寸法の値に合わせて図形を変える。
    /// 多角形の辺は終点を動かし、その先の寸法付きの辺も長さと向きを保ったまま一緒に動かす
    /// (寸法のない辺が伸び縮みして合わせる)
    static func apply(_ kind: DimKind, value v: Double, to shape: inout SketchShape, dimensioned: Set<Int>) {
        guard v > 0 else { return }
        switch kind {
        case .width:
            shape.setRect(origin: shape.rectMin, size: Vec2(v, shape.rectSize.y))
        case .height:
            shape.setRect(origin: shape.rectMin, size: Vec2(shape.rectSize.x, v))
        case .diameter:
            shape.radius = v / 2
        case .length:
            let a = shape.points[0]
            shape.points[1] = a + (shape.points[1] - a).normalized * v
        case .edge(let k):
            let n = shape.points.count
            guard k >= 0, k < n else { return }
            let a = shape.points[k]
            let j = (k + 1) % n
            let target = a + (shape.points[j] - a).normalized * v
            let delta = target - shape.points[j]
            shape.points[j] = target
            // 次の辺も寸法付きなら、その終点も同じだけ動かす(元の点 k まで戻ったら止める)
            var e = j
            while dimensioned.contains(e) {
                let next = (e + 1) % n
                if next == k { break }
                shape.points[next] = shape.points[next] + delta
                e = next
            }
        }
    }

    /// 寸法線を描く位置(画面座標): 測る2点、寸法線の両端、文字の位置
    struct Placement {
        var a: CGPoint
        var b: CGPoint
        var da: CGPoint
        var db: CGPoint
        var label: CGPoint
        var isDiameter: Bool
    }

    static func placement(_ dim: SketchDimension, _ shape: SketchShape, _ vp: SketchViewport) -> Placement? {
        var p0: Vec2, p1: Vec2, outward: Vec2
        switch (dim.kind, shape.kind) {
        case (.width, .rectangle):
            let c = shape.corners
            (p0, p1, outward) = (c[0], c[1], Vec2(0, -1))
        case (.height, .rectangle):
            let c = shape.corners
            (p0, p1, outward) = (c[1], c[2], Vec2(1, 0))
        case (.length, .centerline):
            p0 = shape.points[0]
            p1 = shape.points[1]
            outward = (p1 - p0).normalized.perp
        case (.edge(let k), .polygon):
            let n = shape.points.count
            guard k >= 0, k < n else { return nil }
            p0 = shape.points[k]
            p1 = shape.points[(k + 1) % n]
            let left = (p1 - p0).normalized.perp
            // 外側(図形の外)へ出す
            outward = Polygon2D.signedArea(shape.points) > 0 ? -left : left
        case (.diameter, .circle):
            let c = shape.points[0]
            let dir = Vec2(cos(Double.pi / 4), sin(Double.pi / 4))
            let a = vp.toScreen(c - dir * shape.radius)
            let b = vp.toScreen(c + dir * shape.radius)
            let out = CGPoint(x: b.x + 18, y: b.y - 18)
            return Placement(a: a, b: b, da: a, db: b, label: out, isDiameter: true)
        default:
            return nil
        }
        let a = vp.toScreen(p0), b = vp.toScreen(p1)
        var ox = CGFloat(outward.x), oy = CGFloat(-outward.y)
        let ol = max(hypot(ox, oy), 1e-6)
        ox /= ol
        oy /= ol
        let gap: CGFloat = 26
        let da = CGPoint(x: a.x + ox * gap, y: a.y + oy * gap)
        let db = CGPoint(x: b.x + ox * gap, y: b.y + oy * gap)
        let label = CGPoint(x: (da.x + db.x) / 2 + ox * 2, y: (da.y + db.y) / 2 + oy * 2)
        return Placement(a: a, b: b, da: da, db: db, label: label, isDiameter: false)
    }

    /// 寸法を描く
    static func draw(_ ctx: inout GraphicsContext, _ dim: SketchDimension, _ shape: SketchShape,
                     _ vp: SketchViewport, selected: Bool) {
        guard let p = placement(dim, shape, vp) else { return }
        let color: Color = selected ? .orange : Color(red: 0.1, green: 0.35, blue: 0.85)
        var lines = Path()
        if !p.isDiameter {
            // 補助線
            lines.move(to: p.a); lines.addLine(to: extend(p.a, p.da, 5))
            lines.move(to: p.b); lines.addLine(to: extend(p.b, p.db, 5))
        }
        lines.move(to: p.da); lines.addLine(to: p.db)
        if p.isDiameter { lines.addLine(to: p.label) }
        ctx.stroke(lines, with: .color(color), lineWidth: 1)
        // 矢印
        var arrows = Path()
        arrowHead(&arrows, at: p.da, from: p.db)
        arrowHead(&arrows, at: p.db, from: p.da)
        ctx.fill(arrows, with: .color(color))
        // 数値
        let text = (dim.kind == .diameter ? "⌀" : "") + Format.mm((dim.value * 1000).rounded() / 1000)
        let label = Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(color)
        let resolved = ctx.resolve(label)
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let rect = CGRect(x: p.label.x - size.width / 2 - 4, y: p.label.y - size.height / 2 - 2,
                          width: size.width + 8, height: size.height + 4)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(uiColor: .systemBackground).opacity(0.85)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.6)), lineWidth: selected ? 1.5 : 0.8)
        ctx.draw(resolved, at: p.label, anchor: .center)
    }

    private static func extend(_ from: CGPoint, _ to: CGPoint, _ by: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let l = max(hypot(dx, dy), 1e-6)
        return CGPoint(x: to.x + dx / l * by, y: to.y + dy / l * by)
    }

    private static func arrowHead(_ path: inout Path, at tip: CGPoint, from: CGPoint) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let l = hypot(dx, dy)
        guard l > 1e-6 else { return }
        let ux = dx / l, uy = dy / l
        let size: CGFloat = 8, w: CGFloat = 3
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * w, y: base.y + ux * w))
        path.addLine(to: CGPoint(x: base.x + uy * w, y: base.y - ux * w))
        path.closeSubpath()
    }
}

extension Sketch {
    /// 寸法(古い保存データには無いので省略可)
    var dims: [SketchDimension] {
        get { dimensions ?? [] }
        set { dimensions = newValue.isEmpty ? nil : newValue }
    }
}
