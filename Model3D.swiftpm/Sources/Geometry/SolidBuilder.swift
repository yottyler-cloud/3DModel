import Foundation

/// フィーチャーの履歴からソリッドをつくる
enum SolidBuilder {
    /// フィレット部分の段数
    static let filletSteps = 6
    static let throughAllDistance = 10_000.0

    struct Result {
        var mesh: TriMesh
        var messages: [String]
        var bodyCount: Int
    }

    static func build(_ features: [Feature]) -> Result {
        // ソリッドボディの一覧(「つなげない」押し出しは別のボディになる)
        var bodies: [Solid] = []
        var messages: [String] = []
        for f in effective(features) {
            let shapes = f.sketch.shapes.filter { $0.isProfile }
            if shapes.isEmpty {
                messages.append("「\(f.name)」: スケッチに閉じた図形がありません")
                continue
            }
            if f.kind.isRevolve {
                // 回転・回転カット
                guard let axis = f.sketch.shapes.first(where: { $0.kind == .centerline && $0.isValid }) else {
                    messages.append("「\(f.name)」: 回転の軸にする中心線がスケッチにありません")
                    continue
                }
                guard let tool = revolveSolid(for: f, shapes: shapes, axis: axis) else {
                    messages.append("「\(f.name)」: 輪郭が中心線をまたいでいます。中心線の片側に描いてください")
                    continue
                }
                if f.kind == .revolve {
                    if f.mergeResult {
                        var merged = tool
                        var rest: [Solid] = []
                        for b in bodies {
                            if b.bounds.intersects(tool.bounds, margin: 1e-4) { merged = b.union(merged) } else { rest.append(b) }
                        }
                        bodies = rest + [merged]
                    } else {
                        bodies.append(tool)
                    }
                } else {
                    if bodies.isEmpty { messages.append("「\(f.name)」: 削る形がまだありません") }
                    bodies = bodies.map { $0.subtract(tool) }.filter { !$0.isEmpty }
                }
                continue
            }
            switch f.kind {
            case .extrude:
                if f.mergeResult {
                    // スケッチ面側に形が接していれば、付け根のフィレットは元の面へなだらかにつなぐ
                    let concave = startTouchesBody(f, bodies: bodies)
                    let tool = toolSolid(for: f, shapes: shapes, startConcave: concave)
                    let tb = tool.bounds
                    var merged = tool
                    var rest: [Solid] = []
                    for b in bodies {
                        if b.bounds.intersects(tb, margin: 1e-4) { merged = b.union(merged) } else { rest.append(b) }
                    }
                    bodies = rest + [merged]
                } else {
                    bodies.append(toolSolid(for: f, shapes: shapes, startConcave: false))
                }
            case .cut:
                if bodies.isEmpty { messages.append("「\(f.name)」: 削る形がまだありません") }
                let tool = toolSolid(for: f, shapes: shapes, startConcave: false)
                bodies = bodies.map { $0.subtract(tool) }.filter { !$0.isEmpty }
            default: break
            }
        }
        let all = Solid(polygons: bodies.flatMap { $0.polygons })
        return Result(mesh: TriMesh(solid: all), messages: messages, bodyCount: bodies.count)
    }

    /// 押し出しのスケッチ面側(始まりの面)に、ほかの形が接しているか
    static func startTouchesBody(_ f: Feature, bodies: [Solid]) -> Bool {
        let hasStart = f.startFillet > 0 || (f.sideTreatments ?? []).contains { !$0.atEnd && $0.size > 0 }
        guard hasStart, f.endCondition != .midPlane, !bodies.isEmpty else { return false }
        let (h0, h1, atBottom) = extent(of: f)
        let plane = f.sketch.plane
        let eps = 1e-4
        for b in bodies {
            var lo = Double.infinity, hi = -Double.infinity
            for p in b.polygons { for v in p.vertices {
                let d = plane.distance(v)
                lo = min(lo, d)
                hi = max(hi, d)
            } }
            if atBottom {
                if lo < h0 - eps && hi >= h0 - eps { return true }
            } else {
                if hi > h1 + eps && lo <= h1 + eps { return true }
            }
        }
        return false
    }

    /// フィレット特徴の指定を、対象の押し出し・カットの値に反映した一覧(押し出しとカットだけ)
    static func effective(_ features: [Feature]) -> [Feature] {
        var fs = features.filter { !$0.suppressed }
        // 前から順に反映する(同じエッジは後のフィレット・面取りが優先)
        for f in fs where f.kind.isEdgeFeature {
            let r = max(0, f.filletRadius)
            let isChamfer = f.kind == .chamfer
            for e in f.filletEdges {
                guard let i = fs.firstIndex(where: { $0.id == e.featureID }) else { continue }
                switch e {
                case .start:
                    fs[i].startFillet = r
                    fs[i].startIsChamfer = isChamfer
                case .end:
                    fs[i].endFillet = r
                    fs[i].endIsChamfer = isChamfer
                case .side(_, let shapeID, let k, let atEnd):
                    var list = fs[i].sideTreatments ?? []
                    list.removeAll { $0.shapeID == shapeID && $0.side == k && $0.atEnd == atEnd }
                    list.append(SideTreatment(shapeID: shapeID, side: k, atEnd: atEnd, size: r, chamfer: isChamfer))
                    fs[i].sideTreatments = list
                case .corner(_, let shapeID, let k):
                    if let j = fs[i].sketch.shapes.firstIndex(where: { $0.id == shapeID }) {
                        if isChamfer {
                            fs[i].sketch.shapes[j].setChamfer(r, at: k)
                        } else {
                            fs[i].sketch.shapes[j].setRadius(r, at: k)
                        }
                    }
                }
            }
        }
        return fs.filter { $0.kind.isSolidFeature }
    }

    /// 押し出し・カットの範囲(スケッチ面からの高さ)
    static func extent(of f: Feature) -> (h0: Double, h1: Double, sketchAtBottom: Bool) {
        let through = f.kind == .cut && f.endCondition == .throughAll
        let d = through ? throughAllDistance : max(f.distance, 0.001)
        var r: (Double, Double, Bool)
        if f.endCondition == .midPlane {
            r = (-d / 2, d / 2, true)
        } else {
            r = f.reversed ? (-d, 0, false) : (0, d, true)
        }
        let off = f.useStartOffset ? f.startOffset : 0
        return (r.0 + off, r.1 + off, r.2)
    }

    /// 図形ごとに「外形」か「穴」かを決める(何重に囲まれているか: 偶数で外形)
    static func nestingDepth(_ shapes: [SketchShape]) -> [Int] {
        let outlines = shapes.map { ProfileGeometry.outline($0) }
        var depth = Array(repeating: 0, count: shapes.count)
        for i in shapes.indices {
            let p = Polygon2D.interiorPoint(outlines[i])
            for j in shapes.indices where j != i {
                if Polygon2D.contains(outlines[j], p) { depth[i] += 1 }
            }
        }
        return depth
    }

    /// 端のふちの丸め・面取り(辺ごと)
    struct EndTreatment: Equatable {
        var size: Double = 0
        var chamfer = false
        /// 外側へ広げる(カットの入口・付け根のすみ)
        var flare = false
        static let none = EndTreatment()
    }

    /// その特徴が足す(または削る)形
    static func toolSolid(for f: Feature, shapes: [SketchShape], startConcave: Bool = false) -> Solid {
        let depth = nestingDepth(shapes)
        let (h0, h1, sketchAtBottom) = extent(of: f)
        let isMid = f.endCondition == .midPlane
        let isCut = f.kind == .cut
        let throughAll = isCut && f.endCondition == .throughAll
        let plane = f.sketch.plane
        let sides = f.sideTreatments ?? []

        // 下端(h0)・上端(h1)が、スケッチ面側(start)か先端側(end)か
        let bottomIsEnd = isMid || !sketchAtBottom
        let topIsEnd = isMid || sketchAtBottom
        // 外へ広げる端: カットの入口(スケッチ面側)、付け根が元の形に接している押し出しのスケッチ面側
        let bottomFlare = !bottomIsEnd && (isCut || startConcave)
        let topFlare = !topIsEnd && (isCut || startConcave)

        func treatments(_ shape: SketchShape, bottom: Bool) -> [EndTreatment] {
            let isEnd = bottom ? bottomIsEnd : topIsEnd
            let flare = bottom ? bottomFlare : topFlare
            // 貫通カットの先は丸めない
            if throughAll && isEnd { return Array(repeating: .none, count: ProfileGeometry.sideCount(shape)) }
            let size = isEnd ? f.endFillet : f.startFillet
            let chamfer = isEnd ? (f.endIsChamfer ?? false) : (f.startIsChamfer ?? false)
            var list = Array(repeating: EndTreatment(size: size, chamfer: chamfer, flare: flare),
                             count: ProfileGeometry.sideCount(shape))
            for t in sides where t.shapeID == shape.id && t.atEnd == isEnd && t.side < list.count {
                list[t.side] = EndTreatment(size: t.size, chamfer: t.chamfer, flare: flare)
            }
            return list
        }

        var body = Solid.empty
        var holes = Solid.empty
        let ext = 0.01
        for (i, shape) in shapes.enumerated() {
            if depth[i] % 2 == 0 {
                body = body.union(Solid(polygons: prism(
                    shape: shape, plane: plane, h0: h0, h1: h1,
                    bottom: treatments(shape, bottom: true), top: treatments(shape, bottom: false))))
            } else if isCut {
                // カットの中の島
                holes = holes.union(Solid(polygons: prism(
                    shape: shape, plane: plane, h0: h0 - ext, h1: h1 + ext, bottom: [], top: [])))
            } else {
                // 押し出しの中の穴: 外へ広げた道具で、穴の入口のふちも丸める
                // (付け根が元の形に接している側は穴のふちにならないので、そのまま)
                func holeEnd(_ bottom: Bool) -> [EndTreatment] {
                    let flareSide = bottom ? bottomFlare : topFlare
                    if startConcave && flareSide { return [] }
                    let isEnd = bottom ? bottomIsEnd : topIsEnd
                    let size = isEnd ? f.endFillet : f.startFillet
                    let chamfer = isEnd ? (f.endIsChamfer ?? false) : (f.startIsChamfer ?? false)
                    guard size > 0 else { return [] }
                    return [EndTreatment(size: size + ext, chamfer: chamfer, flare: true)]
                }
                holes = holes.union(Solid(polygons: prism(
                    shape: shape, plane: plane, h0: h0 - ext, h1: h1 + ext,
                    bottom: holeEnd(true), top: holeEnd(false))))
            }
        }
        return body.subtract(holes)
    }

    /// 図形を h0〜h1 まで押し出した柱。両端のふちを、辺ごとに丸め・面取りできる。
    /// bottom・top は図形の辺の番号順(足りない分は何もしない。1つだけなら全部の辺に使う)
    static func prism(shape: SketchShape, plane: SketchPlane, h0: Double, h1: Double,
                      bottom: [EndTreatment], top: [EndTreatment]) -> [CSGPolygon] {
        let height = h1 - h0
        let n = ProfileGeometry.sideCount(shape)
        guard height > 1e-9, n > 0 else { return [] }
        func expand(_ t: [EndTreatment]) -> [EndTreatment] {
            if t.count == 1 { return Array(repeating: t[0], count: n) }
            return (0..<n).map { $0 < t.count ? t[$0] : .none }
        }
        var bot = expand(bottom), tp = expand(top)

        // 上下の丸めが重ならないように
        let bm = bot.map(\.size).max() ?? 0, tm = tp.map(\.size).max() ?? 0
        if bm + tm > height * 0.999 {
            let s = height * 0.999 / (bm + tm)
            for i in 0..<n { bot[i].size *= s; tp[i].size *= s }
        }
        // 内側へずらす量が大きすぎて形がつぶれるなら、小さくする
        var tries = 0
        while tries < 40 {
            let inward = (0..<n).map { i in
                max(bot[i].flare ? 0 : bot[i].size, tp[i].flare ? 0 : tp[i].size)
            }
            if inward.allSatisfy({ $0 < 1e-9 }) || ProfileGeometry.insetIsValid(shape, sideInsets: inward) { break }
            for i in 0..<n {
                if !bot[i].flare { bot[i].size *= 0.85 }
                if !tp[i].flare { tp[i].size *= 0.85 }
            }
            tries += 1
        }
        if tries >= 40 {
            for i in 0..<n {
                if !bot[i].flare { bot[i].size = 0 }
                if !tp[i].flare { tp[i].size = 0 }
            }
        }

        // 端からの距離 u での、ずらし量
        func profile(_ t: EndTreatment, _ u: Double) -> Double {
            guard t.size > 1e-6, u < t.size - 1e-12 else { return 0 }
            let v = t.chamfer ? t.size - u : t.size - (max(0, t.size * t.size - (t.size - u) * (t.size - u))).squareRoot()
            return t.flare ? -v : v
        }
        func insets(at h: Double) -> [Double] {
            (0..<n).map { i in profile(bot[i], h - h0) + profile(tp[i], h1 - h) }
        }

        // 段の高さ
        var hs: [Double] = [h0, h1]
        let steps = filletSteps
        for t in Set(bot.filter { $0.size > 1e-6 }.map { [$0.size, $0.chamfer ? 1 : 0] }) {
            let size = t[0]
            if t[1] == 1 {
                hs.append(h0 + size)
            } else {
                for k in 1...steps { hs.append(h0 + size * (1 - cos(Double.pi / 2 * Double(k) / Double(steps)))) }
            }
        }
        for t in Set(tp.filter { $0.size > 1e-6 }.map { [$0.size, $0.chamfer ? 1 : 0] }) {
            let size = t[0]
            if t[1] == 1 {
                hs.append(h1 - size)
            } else {
                for k in 1...steps { hs.append(h1 - size * (1 - cos(Double.pi / 2 * Double(k) / Double(steps)))) }
            }
        }
        hs.sort()
        var heights: [Double] = []
        for h in hs where h >= h0 - 1e-12 && h <= h1 + 1e-12 {
            if let last = heights.last, h - last < 1e-7 { continue }
            heights.append(h)
        }
        if let last = heights.last, abs(last - h1) > 1e-9 { heights.append(h1) }
        guard heights.count >= 2 else { return [] }

        let loops2 = heights.map { ProfileGeometry.outline(shape, sideInsets: insets(at: $0)) }
        let loops = zip(heights, loops2).map { h, l in l.map { plane.point($0, height: h) } }
        var polys: [CSGPolygon] = []
        func addTri(_ a: Vec3, _ b: Vec3, _ c: Vec3) {
            if let p = CSGPolygon(vertices: [a, b, c]) { polys.append(p) }
        }
        // 側面
        for k in 0..<(loops.count - 1) {
            let lower = loops[k], upper = loops[k + 1]
            let m = lower.count
            for i in 0..<m {
                let j = (i + 1) % m
                addTri(lower[i], lower[j], upper[j])
                addTri(lower[i], upper[j], upper[i])
            }
        }
        // ふた(両端の面)
        for (index, isTop) in [(0, false), (heights.count - 1, true)] {
            let pts2 = Polygon2D.dedupe(loops2[index])
            guard pts2.count >= 3 else { continue }
            let pts3 = pts2.map { plane.point($0, height: heights[index]) }
            for t in Polygon2D.triangulate(pts2) {
                if isTop {
                    addTri(pts3[t.0], pts3[t.1], pts3[t.2])
                } else {
                    addTri(pts3[t.0], pts3[t.2], pts3[t.1])
                }
            }
        }
        return polys
    }

    static let revolveSegments = 48

    /// 中心線を軸にスケッチを回した形(輪郭が軸をまたぐと nil)
    static func revolveSolid(for f: Feature, shapes: [SketchShape], axis: SketchShape) -> Solid? {
        let depth = nestingDepth(shapes)
        var body = Solid.empty
        var holes = Solid.empty
        for i in shapes.indices {
            guard let polys = revolve(shape: shapes[i], feature: f, axis: axis) else { return nil }
            if depth[i] % 2 == 0 {
                body = body.union(Solid(polygons: polys))
            } else {
                holes = holes.union(Solid(polygons: polys))
            }
        }
        return body.subtract(holes)
    }

    /// 1つの輪郭を回す
    static func revolve(shape: SketchShape, feature f: Feature, axis: SketchShape) -> [CSGPolygon]? {
        let plane = f.sketch.plane
        let a = axis.points[0]
        let d = (axis.points[1] - a).normalized
        var perp = Vec2(-d.y, d.x)
        let pts = Polygon2D.dedupe(ProfileGeometry.outline(shape))
        guard pts.count >= 3 else { return [] }
        // 軸からの距離(片側にあること)
        var radial = pts.map { ($0 - a).dot(perp) }
        let eps = 1e-6
        if (radial.max() ?? 0) <= eps {
            perp = -perp
            radial = radial.map { -$0 }
        }
        if (radial.min() ?? 0) < -eps { return nil }
        let along = pts.map { ($0 - a).dot(d) }
        let e1 = plane.u * perp.x + plane.v * perp.y
        let e2 = plane.normal

        let total = max(0.1, min(f.distance, 360)) * Double.pi / 180
        let full = total >= 2 * Double.pi - 1e-9
        var start = 0.0
        if f.endCondition == .midPlane {
            start = -total / 2
        } else if f.reversed {
            start = -total
        }
        let steps = full ? revolveSegments : max(2, Int((Double(revolveSegments) * total / (2 * Double.pi)).rounded(.up)))
        func point(_ i: Int, _ k: Int) -> Vec3 {
            let ang = start + total * Double(k) / Double(steps)
            let base = plane.point(a + d * along[i])
            return base + (e1 * cos(ang) + e2 * sin(ang)) * max(radial[i], 0)
        }
        var polys: [CSGPolygon] = []
        func addTri(_ p: Vec3, _ q: Vec3, _ r: Vec3) {
            if let poly = CSGPolygon(vertices: [p, q, r]) { polys.append(poly) }
        }
        let n = pts.count
        for k in 0..<steps {
            let k2 = full && k == steps - 1 ? 0 : k + 1
            for i in 0..<n {
                let j = (i + 1) % n
                addTri(point(i, k), point(j, k), point(j, k2))
                addTri(point(i, k), point(j, k2), point(i, k2))
            }
        }
        if !full {
            // 回し始めと回し終わりの断面
            for t in Polygon2D.triangulate(pts) {
                addTri(point(t.0, 0), point(t.2, 0), point(t.1, 0))
                addTri(point(t.0, steps), point(t.1, steps), point(t.2, steps))
            }
        }
        // 向き(外向き)を体積の符号でそろえる
        var vol = 0.0
        for p in polys {
            let v = p.vertices
            vol += v[0].dot(v[1].cross(v[2]))
        }
        if vol < 0 { polys = polys.map { $0.flipped() } }
        return polys
    }

    /// 内側へずらせる上限までRを小さくする
    static func limitInset(_ shape: SketchShape, _ r: Double) -> Double {
        var r = r
        var tries = 0
        while r > 1e-6 && !ProfileGeometry.insetIsValid(shape, inset: r) && tries < 40 {
            r *= 0.85
            tries += 1
        }
        return tries >= 40 ? 0 : r
    }
}
