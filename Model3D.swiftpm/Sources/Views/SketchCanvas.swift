import SwiftUI

/// スケッチの描画内容
struct SketchDrawing {
    var shapes: [SketchShape]
    var references: [SketchShape]
    var selection: UUID?
    var axisLabels: (String, String)
    /// 作図中のプレビュー
    var previewShape: SketchShape?
    var polyPoints: [Vec2]
    var cursor: Vec2?
    var highlightCorner: Vec2?
    /// スケッチに残した寸法
    var dimensions: [SketchDimension] = []

    func draw(_ ctx: inout GraphicsContext, size: CGSize, vp: SketchViewport) {
        drawGrid(&ctx, size: size, vp: vp)

        // 参照(ほかの特徴のスケッチ)
        for s in references where s.isValid {
            ctx.stroke(path(s, vp), with: .color(.gray.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }

        // 図形(偶奇で塗ると、内側の図形が穴に見える)
        var all = Path()
        for s in shapes where s.isProfile { all.addPath(path(s, vp)) }
        ctx.fill(all, with: .color(.accentColor.opacity(0.10)), style: FillStyle(eoFill: true))
        for s in shapes where s.isValid && s.kind == .centerline {
            // 中心線(回転の軸)は一点鎖線
            let selected = s.id == selection
            var line = Path()
            line.move(to: vp.toScreen(s.points[0]))
            line.addLine(to: vp.toScreen(s.points[1]))
            ctx.stroke(line, with: .color(selected ? .orange : .brown),
                       style: StrokeStyle(lineWidth: selected ? 2.2 : 1.4, dash: [14, 4, 3, 4]))
        }
        for s in shapes where s.isProfile {
            let selected = s.id == selection
            ctx.stroke(path(s, vp), with: .color(selected ? .orange : .blue),
                       lineWidth: selected ? 2.5 : 1.6)
            drawLabels(&ctx, s, vp: vp, showSize: !dimensions.contains { $0.shapeID == s.id })
        }
        // 寸法
        for d in dimensions {
            guard let shape = shapes.first(where: { $0.id == d.shapeID }) else { continue }
            DimensionMath.draw(&ctx, d, shape, vp, selected: d.shapeID == selection)
        }

        if let p = previewShape, p.isValid {
            ctx.stroke(p.kind == .centerline ? linePath(p, vp) : path(p, vp), with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            drawLabels(&ctx, p, vp: vp)
        }

        if !polyPoints.isEmpty {
            var pl = Path()
            pl.move(to: vp.toScreen(polyPoints[0]))
            for p in polyPoints.dropFirst() { pl.addLine(to: vp.toScreen(p)) }
            if let c = cursor { pl.addLine(to: vp.toScreen(c)) }
            ctx.stroke(pl, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            for (i, p) in polyPoints.enumerated() {
                let s = vp.toScreen(p)
                let r: CGFloat = i == 0 ? 7 : 4
                ctx.stroke(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)),
                           with: .color(.orange), lineWidth: 1.5)
            }
        }

        if let c = cursor {
            let s = vp.toScreen(c)
            var cross = Path()
            cross.move(to: CGPoint(x: s.x - 9, y: s.y)); cross.addLine(to: CGPoint(x: s.x + 9, y: s.y))
            cross.move(to: CGPoint(x: s.x, y: s.y - 9)); cross.addLine(to: CGPoint(x: s.x, y: s.y + 9))
            ctx.stroke(cross, with: .color(.orange), lineWidth: 1)
            ctx.draw(Text("(\(Format.mm(c.x)), \(Format.mm(c.y)))").font(.caption2).foregroundColor(.orange),
                     at: CGPoint(x: s.x + 12, y: s.y - 12), anchor: .bottomLeading)
        }

        if let h = highlightCorner {
            let s = vp.toScreen(h)
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 10, y: s.y - 10, width: 20, height: 20)),
                       with: .color(.orange), lineWidth: 2)
        }
    }

    func linePath(_ s: SketchShape, _ vp: SketchViewport) -> Path {
        var p = Path()
        p.move(to: vp.toScreen(s.points[0]))
        p.addLine(to: vp.toScreen(s.points[1]))
        return p
    }

    func path(_ s: SketchShape, _ vp: SketchViewport) -> Path {
        var p = Path()
        let pts = ProfileGeometry.outline(s)
        guard let first = pts.first else { return p }
        p.move(to: vp.toScreen(first))
        for q in pts.dropFirst() { p.addLine(to: vp.toScreen(q)) }
        p.closeSubpath()
        return p
    }

    private func drawLabels(_ ctx: inout GraphicsContext, _ s: SketchShape, vp: SketchViewport, showSize: Bool = true) {
        switch s.kind {
        case .rectangle where showSize:
            let a = s.rectMin, sz = s.rectSize
            let top = vp.toScreen(Vec2(a.x + sz.x / 2, a.y + sz.y))
            ctx.draw(Text("\(Format.mm(sz.x)) × \(Format.mm(sz.y))").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: top.x, y: top.y - 4), anchor: .bottom)
        case .circle where showSize:
            let c = vp.toScreen(s.points[0])
            ctx.draw(Text("⌀\(Format.mm(s.radius * 2))").font(.caption2).foregroundColor(.secondary),
                     at: c, anchor: .center)
        case .rectangle, .circle, .polygon, .centerline:
            break
        }
        // 角のR
        for (i, p) in s.corners.enumerated() {
            let sp = vp.toScreen(p)
            let r = s.radius(at: i)
            let c = s.chamfer(at: i)
            if c > 0 && r <= 0 {
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x - 3, y: sp.y - 3, width: 6, height: 6)), with: .color(.purple))
                ctx.draw(Text("C\(Format.mm(c))").font(.caption2.bold()).foregroundColor(.purple),
                         at: CGPoint(x: sp.x + 5, y: sp.y + 5), anchor: .topLeading)
            } else if r > 0 {
                ctx.fill(Path(ellipseIn: CGRect(x: sp.x - 3, y: sp.y - 3, width: 6, height: 6)), with: .color(.pink))
                ctx.draw(Text("R\(Format.mm(r))").font(.caption2.bold()).foregroundColor(.pink),
                         at: CGPoint(x: sp.x + 5, y: sp.y + 5), anchor: .topLeading)
            } else {
                ctx.stroke(Path(ellipseIn: CGRect(x: sp.x - 2.5, y: sp.y - 2.5, width: 5, height: 5)),
                           with: .color(.secondary), lineWidth: 1)
            }
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize, vp: SketchViewport) {
        let w0 = vp.toWorld(CGPoint(x: 0, y: size.height))
        let w1 = vp.toWorld(CGPoint(x: size.width, y: 0))
        let step = vp.gridStep, major = vp.majorStep
        var minorPath = Path(), majorPath = Path()
        var x = floor(w0.x / step) * step
        while x <= w1.x {
            let isMajor = abs(x / major - (x / major).rounded()) < 1e-6
            let sx = vp.toScreen(Vec2(x, 0)).x
            var p = isMajor ? majorPath : minorPath
            p.move(to: CGPoint(x: sx, y: 0)); p.addLine(to: CGPoint(x: sx, y: size.height))
            if isMajor { majorPath = p } else { minorPath = p }
            x += step
        }
        var y = floor(w0.y / step) * step
        while y <= w1.y {
            let isMajor = abs(y / major - (y / major).rounded()) < 1e-6
            let sy = vp.toScreen(Vec2(0, y)).y
            var p = isMajor ? majorPath : minorPath
            p.move(to: CGPoint(x: 0, y: sy)); p.addLine(to: CGPoint(x: size.width, y: sy))
            if isMajor { majorPath = p } else { minorPath = p }
            y += step
        }
        ctx.stroke(minorPath, with: .color(.gray.opacity(0.10)), lineWidth: 0.5)
        ctx.stroke(majorPath, with: .color(.gray.opacity(0.22)), lineWidth: 0.8)

        let o = vp.toScreen(.zero)
        var ax = Path(); ax.move(to: CGPoint(x: 0, y: o.y)); ax.addLine(to: CGPoint(x: size.width, y: o.y))
        var ay = Path(); ay.move(to: CGPoint(x: o.x, y: 0)); ay.addLine(to: CGPoint(x: o.x, y: size.height))
        ctx.stroke(ax, with: .color(.red.opacity(0.6)), lineWidth: 1)
        ctx.stroke(ay, with: .color(.green.opacity(0.7)), lineWidth: 1)
        ctx.draw(Text(axisLabels.0).font(.caption.bold()).foregroundColor(.red),
                 at: CGPoint(x: size.width - 14, y: o.y - 10))
        ctx.draw(Text(axisLabels.1).font(.caption.bold()).foregroundColor(.green),
                 at: CGPoint(x: o.x + 12, y: 14))
        ctx.draw(Text("格子 \(Format.mm(step)) mm").font(.caption2).foregroundColor(.secondary),
                 at: CGPoint(x: 10, y: size.height - 10), anchor: .bottomLeading)
    }
}
