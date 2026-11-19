import SwiftUI

enum SketchTool: String, CaseIterable, Identifiable {
    case select, line, cornerRect, centerRect, circle, sketchFillet, dimension
    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "選択"
        case .line: return "直線"
        case .cornerRect: return "コーナー矩形"
        case .centerRect: return "中心矩形"
        case .circle: return "円"
        case .sketchFillet: return "スケッチフィレット"
        case .dimension: return "スマート寸法"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .cornerRect: return "rectangle"
        case .centerRect: return "plus.rectangle"
        case .circle: return "circle"
        case .sketchFillet: return "square.on.circle"
        case .dimension: return "ruler"
        }
    }

    var hint: String {
        switch self {
        case .select: return "図形をタップで選択、ドラッグで移動"
        case .line: return "点を順にタップ。最初の点をタップすると閉じる"
        case .cornerRect: return "1つ目の角から対角へドラッグ"
        case .centerRect: return "中心から角へドラッグ"
        case .circle: return "中心から外へドラッグ"
        case .sketchFillet: return "角をタップして丸める(もう一度で外す)"
        case .dimension: return "辺や円をタップして寸法を入力"
        }
    }
}

/// スマート寸法の入力
struct DimensionEdit: Identifiable {
    enum Kind { case width, height, diameter, edge(Int) }
    var id = UUID()
    var shapeID: UUID
    var kind: Kind
    var title: String
    var text: String
}

/// スケッチ画面の表示倍率と位置
struct SketchViewport {
    var scale: CGFloat
    var origin: CGPoint

    func toScreen(_ p: Vec2) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y - CGFloat(p.y) * scale)
    }

    func toWorld(_ s: CGPoint) -> Vec2 {
        Vec2(Double((s.x - origin.x) / scale), Double((origin.y - s.y) / scale))
    }

    /// 画面上でおよそ12pt以上になる格子の間隔(mm)
    var gridStep: Double {
        let steps: [Double] = [0.1, 0.5, 1, 5, 10, 50, 100, 500, 1000]
        for s in steps where CGFloat(s) * scale >= 12 { return s }
        return 1000
    }

    var majorStep: Double {
        let s = gridStep
        let mantissa = s / pow(10, floor(log10(s)))
        return mantissa < 2 ? s * 10 : s * 2
    }
}

/// スケッチの外から渡す情報
struct SketchEnv {
    var size: CGSize
    /// 同じ平面にあるほかのスケッチ
    var references: [SketchShape]
    /// 平面上にある形の稜線の点
    var modelPoints: [Vec2]
}

/// スケッチ中の状態と操作
struct SketchSession {
    var feature: Feature
    /// 新しいスケッチか(既存フィーチャーのスケッチ編集なら false)
    var isNew: Bool
    /// スケッチ終了のあとに続けて行う押し出し・カット
    var continueWith: FeatureKind?

    var tool: SketchTool = .line
    var scale: CGFloat = 5
    var pan: CGSize = .zero
    var selection: UUID?
    var dragStart: Vec2?
    var dragCurrent: Vec2?
    var polyPoints: [Vec2] = []
    var cursor: Vec2?
    var moveAnchor: Vec2?
    var moveOriginal: SketchShape?
    var cornerR: Double = 3
    var snapToGrid = true
    var undoStack: [[SketchShape]] = []
    var dimension: DimensionEdit?

    var shapes: [SketchShape] {
        get { feature.sketch.shapes }
        set { feature.sketch.shapes = newValue }
    }

    var plane: SketchPlane { feature.sketch.plane }

    func viewport(_ size: CGSize) -> SketchViewport {
        SketchViewport(scale: scale,
                       origin: CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height))
    }

    /// いま画面中央に見えているスケッチ座標と、画面の高さの半分(mm)
    func cameraFrame(_ size: CGSize) -> (center: Vec2, halfHeight: Double) {
        let c = viewport(size).toWorld(CGPoint(x: size.width / 2, y: size.height / 2))
        return (c, Double(size.height / 2 / scale))
    }

    // MARK: 入力

    mutating func began(_ s: CGPoint, _ env: SketchEnv) {
        let vp = viewport(env.size)
        switch tool {
        case .cornerRect, .centerRect, .circle:
            let p = snap(s, env)
            dragStart = p
            dragCurrent = p
        case .line:
            cursor = snap(s, env)
        case .select:
            selection = hitShape(s, env)
            if let id = selection, let shape = shapes.first(where: { $0.id == id }) {
                moveAnchor = vp.toWorld(s)
                moveOriginal = shape
            }
        case .sketchFillet, .dimension:
            break
        }
    }

    mutating func moved(_ s: CGPoint, _ env: SketchEnv) {
        let vp = viewport(env.size)
        switch tool {
        case .cornerRect, .centerRect, .circle:
            if dragStart != nil { dragCurrent = snap(s, env) }
        case .line:
            cursor = snap(s, env)
        case .select:
            guard let anchor = moveAnchor, let original = moveOriginal,
                  let i = shapes.firstIndex(where: { $0.id == original.id }) else { return }
            if shapes[i] == original && undoStack.last != shapes { pushUndo() }
            let ref = original.points[0]
            let target = snapWorld(ref + (vp.toWorld(s) - anchor), env, excluding: original.id)
            var moved = original
            moved.translate(by: target - ref)
            shapes[i] = moved
        case .sketchFillet, .dimension:
            break
        }
    }

    mutating func ended(_ s: CGPoint, _ env: SketchEnv) {
        let vp = viewport(env.size)
        switch tool {
        case .cornerRect, .centerRect:
            if let a = dragStart {
                let b = snap(s, env)
                if abs(a.x - b.x) > 1e-6 && abs(a.y - b.y) > 1e-6 {
                    addShape(tool == .cornerRect ? .rectangle(a, b) : .centerRectangle(center: a, corner: b))
                }
            }
            dragStart = nil
            dragCurrent = nil
        case .circle:
            if let a = dragStart {
                let r = a.distance(to: snap(s, env))
                if r > 1e-6 { addShape(.circle(center: a, radius: (r * 1000).rounded() / 1000)) }
            }
            dragStart = nil
            dragCurrent = nil
        case .line:
            let p = snap(s, env)
            let first = polyPoints.first.map { vp.toScreen($0) }
            if polyPoints.count >= 3, let f = first, hypot(f.x - s.x, f.y - s.y) < 22 {
                finishPolygon()
            } else if polyPoints.last.map({ $0.distance(to: p) > 1e-6 }) ?? true {
                polyPoints.append(p)
            }
            cursor = nil
        case .select:
            moveAnchor = nil
            moveOriginal = nil
        case .sketchFillet:
            toggleFillet(at: s, env)
        case .dimension:
            startDimension(at: s, env)
        }
    }

    mutating func cancelInProgress() {
        dragStart = nil
        dragCurrent = nil
        cursor = nil
        if let original = moveOriginal, let i = shapes.firstIndex(where: { $0.id == original.id }) {
            shapes[i] = original
        }
        moveAnchor = nil
        moveOriginal = nil
    }

    mutating func finishPolygon() {
        if polyPoints.count >= 3 {
            let shape = SketchShape.polygon(polyPoints)
            if shape.isValid { addShape(shape) }
        }
        polyPoints = []
        cursor = nil
    }

    mutating func addShape(_ shape: SketchShape) {
        pushUndo()
        shapes.append(shape)
        selection = shape.id
    }

    mutating func deleteShape(_ id: UUID) {
        pushUndo()
        if selection == id { selection = nil }
        shapes.removeAll { $0.id == id }
    }

    mutating func pushUndo() {
        undoStack.append(shapes)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    mutating func undo() {
        if !polyPoints.isEmpty {
            polyPoints.removeLast()
            return
        }
        guard let last = undoStack.popLast() else { return }
        shapes = last
        if let s = selection, !last.contains(where: { $0.id == s }) { selection = nil }
    }

    mutating func setAllCornerRadii(_ r: Double) {
        pushUndo()
        for i in shapes.indices { shapes[i].setAllRadii(r) }
    }

    private mutating func toggleFillet(at s: CGPoint, _ env: SketchEnv) {
        let vp = viewport(env.size)
        var best: (shape: Int, corner: Int, d: CGFloat)?
        for (si, shape) in shapes.enumerated() {
            for (ci, c) in shape.corners.enumerated() {
                let sp = vp.toScreen(c)
                let d = hypot(sp.x - s.x, sp.y - s.y)
                if d < 28 && d < (best?.d ?? .infinity) { best = (si, ci, d) }
            }
        }
        guard let b = best else { return }
        pushUndo()
        let current = shapes[b.shape].radius(at: b.corner)
        shapes[b.shape].setRadius(abs(current - cornerR) < 1e-9 ? 0 : cornerR, at: b.corner)
        selection = shapes[b.shape].id
    }

    // MARK: スマート寸法

    private mutating func startDimension(at s: CGPoint, _ env: SketchEnv) {
        let vp = viewport(env.size)
        let w = vp.toWorld(s)
        let tol = Double(16 / scale)
        var best: (DimensionEdit, Double)?
        func consider(_ d: DimensionEdit, _ dist: Double) {
            if dist < tol && dist < (best?.1 ?? .infinity) { best = (d, dist) }
        }
        for shape in shapes where shape.isValid {
            switch shape.kind {
            case .rectangle:
                let c = shape.corners
                let size = shape.rectSize
                for i in 0..<4 {
                    let d = Polygon2D.distanceToSegment(w, c[i], c[(i + 1) % 4])
                    let horizontal = i % 2 == 0
                    consider(DimensionEdit(shapeID: shape.id, kind: horizontal ? .width : .height,
                                           title: horizontal ? "幅" : "高さ",
                                           text: Format.mm(horizontal ? size.x : size.y)), d)
                }
            case .circle:
                let d = abs(w.distance(to: shape.points[0]) - shape.radius)
                consider(DimensionEdit(shapeID: shape.id, kind: .diameter, title: "直径",
                                       text: Format.mm(shape.radius * 2)), d)
            case .polygon:
                let p = shape.points
                for i in p.indices {
                    let a = p[i], b = p[(i + 1) % p.count]
                    consider(DimensionEdit(shapeID: shape.id, kind: .edge(i), title: "長さ",
                                           text: Format.mm(a.distance(to: b))),
                             Polygon2D.distanceToSegment(w, a, b))
                }
            }
        }
        if let b = best {
            selection = b.0.shapeID
            dimension = b.0
        }
    }

    mutating func applyDimension() {
        guard let d = dimension else { return }
        dimension = nil
        let text = d.text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(text), v > 0,
              let i = shapes.firstIndex(where: { $0.id == d.shapeID }) else { return }
        pushUndo()
        var shape = shapes[i]
        switch d.kind {
        case .width: shape.setRect(origin: shape.rectMin, size: Vec2(v, shape.rectSize.y))
        case .height: shape.setRect(origin: shape.rectMin, size: Vec2(shape.rectSize.x, v))
        case .diameter: shape.radius = v / 2
        case .edge(let k):
            let a = shape.points[k], j = (k + 1) % shape.points.count
            let dir = (shape.points[j] - a).normalized
            shape.points[j] = a + dir * v
        }
        shapes[i] = shape
    }

    // MARK: スナップ・選択

    func snap(_ s: CGPoint, _ env: SketchEnv) -> Vec2 {
        snapWorld(viewport(env.size).toWorld(s), env, excluding: nil)
    }

    func snapWorld(_ w: Vec2, _ env: SketchEnv, excluding: UUID?) -> Vec2 {
        let vp = viewport(env.size)
        let sp = vp.toScreen(w)
        var candidates: [Vec2] = [.zero]
        for shape in shapes where shape.id != excluding { candidates += shape.snapPoints }
        for shape in env.references { candidates += shape.snapPoints }
        candidates += env.modelPoints
        candidates += polyPoints
        var best: Vec2?
        var bestD: CGFloat = 14
        for c in candidates {
            let cs = vp.toScreen(c)
            let d = hypot(cs.x - sp.x, cs.y - sp.y)
            if d < bestD {
                bestD = d
                best = c
            }
        }
        if let best { return best }
        if snapToGrid {
            let step = vp.gridStep
            return Vec2((w.x / step).rounded() * step, (w.y / step).rounded() * step)
        }
        return Vec2((w.x * 1000).rounded() / 1000, (w.y * 1000).rounded() / 1000)
    }

    func hitShape(_ s: CGPoint, _ env: SketchEnv) -> UUID? {
        let w = viewport(env.size).toWorld(s)
        let tol = Double(12 / scale)
        var best: (UUID, Double)?
        for shape in shapes where shape.isValid {
            let d = Polygon2D.distanceToOutline(ProfileGeometry.outline(shape), w)
            if d < tol && d < (best?.1 ?? .infinity) { best = (shape.id, d) }
        }
        if let best { return best.0 }
        var inside: (UUID, Double)?
        for shape in shapes where shape.isValid {
            let pts = ProfileGeometry.outline(shape)
            if Polygon2D.contains(pts, w) {
                let area = abs(Polygon2D.signedArea(pts))
                if area < (inside?.1 ?? .infinity) { inside = (shape.id, area) }
            }
        }
        return inside?.0
    }

    // MARK: 表示

    mutating func zoom(by s: CGFloat, around c: CGPoint, size: CGSize) {
        let before = viewport(size).toWorld(c)
        scale = min(max(scale * s, 0.05), 400)
        let after = viewport(size).toScreen(before)
        pan.width += c.x - after.x
        pan.height += c.y - after.y
    }

    /// 点がすべて見えるように合わせる
    mutating func fit(size: CGSize, points extra: [Vec2]) {
        var pts = extra
        for s in shapes where s.isValid { pts += ProfileGeometry.outline(s) }
        if pts.isEmpty { pts = [Vec2(-50, -50), Vec2(50, 50)] }
        pts.append(.zero)
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let sz = size.width < 10 ? CGSize(width: 700, height: 600) : size
        scale = min((sz.width - 120) / CGFloat(w), (sz.height - 160) / CGFloat(h))
        scale = min(max(scale, 0.05), 400)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        pan = CGSize(width: -CGFloat(cx) * scale, height: CGFloat(cy) * scale)
    }
}
