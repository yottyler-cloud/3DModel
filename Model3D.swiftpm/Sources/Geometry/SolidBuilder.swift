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
            let shapes = f.sketch.shapes.filter { $0.isValid }
            if shapes.isEmpty {
                messages.append("「\(f.name)」: スケッチに閉じた図形がありません")
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
        guard f.startFillet > 0, f.endCondition != .midPlane, !bodies.isEmpty else { return false }
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
        for f in fs where f.kind == .fillet {
            let r = max(0, f.filletRadius)
            for e in f.filletEdges {
                guard let i = fs.firstIndex(where: { $0.id == e.featureID }) else { continue }
                switch e {
                case .start:
                    fs[i].startFillet = max(fs[i].startFillet, r)
                case .end:
                    fs[i].endFillet = max(fs[i].endFillet, r)
                case .corner(_, let shapeID, let k):
                    if let j = fs[i].sketch.shapes.firstIndex(where: { $0.id == shapeID }) {
                        let cur = fs[i].sketch.shapes[j].radius(at: k)
                        fs[i].sketch.shapes[j].setRadius(max(cur, r), at: k)
                    }
                }
            }
        }
        return fs.filter { $0.kind == .extrude || $0.kind == .cut }
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

    /// その特徴が足す(または削る)形
    static func toolSolid(for f: Feature, shapes: [SketchShape], startConcave: Bool = false) -> Solid {
        let depth = nestingDepth(shapes)
        let (h0, h1, sketchAtBottom) = extent(of: f)
        let isMid = f.endCondition == .midPlane
        // フィレットを下端(h0)・上端(h1)へ割り当てる
        let startR = f.startFillet, endR = f.endFillet
        var bottomR = sketchAtBottom ? startR : endR
        var topR = sketchAtBottom ? endR : startR
        if isMid {
            // 中間平面のときは両端とも「先端」
            bottomR = endR
            topR = endR
        }
        // カット: 入口(スケッチ面側)のふちは凸 → 道具を外へ広げる。先端(底)は道具を内へ丸める
        let isCut = f.kind == .cut
        let bottomIsEntry = isCut && sketchAtBottom && !isMid
        let topIsEntry = isCut && !sketchAtBottom
        let throughAll = isCut && f.endCondition == .throughAll

        var body = Solid.empty
        var holes = Solid.empty
        let ext = 0.01
        for i in shapes.indices {
            if depth[i] % 2 == 0 {
                var bR = bottomR, tR = topR
                if throughAll {
                    // 貫通する側の先端は丸めない
                    if !bottomIsEntry { bR = 0 }
                    if !topIsEntry { tR = 0 }
                }
                // 押し出しの付け根(元の形に接するスケッチ面側)は外へ広げて、すみRにする
                let bConcave = startConcave && sketchAtBottom
                let tConcave = startConcave && !sketchAtBottom
                body = body.union(Solid(polygons: prism(
                    shape: shapes[i], plane: f.sketch.plane, h0: h0, h1: h1,
                    bottomR: bR, topR: tR,
                    bottomFlare: (isCut && bottomIsEntry) || bConcave,
                    topFlare: (isCut && topIsEntry) || tConcave)))
            } else if isCut {
                // カットの中の島
                holes = holes.union(Solid(polygons: prism(
                    shape: shapes[i], plane: f.sketch.plane, h0: h0 - ext, h1: h1 + ext,
                    bottomR: 0, topR: 0, bottomFlare: false, topFlare: false)))
            } else {
                // 押し出しの中の穴(外へ広げた道具で、穴の入口のふちも丸める)
                // (付け根が元の形に接している側は、穴のふちにならないので丸めない)
                let bR = startConcave && sketchAtBottom ? 0 : bottomR
                let tR = startConcave && !sketchAtBottom ? 0 : topR
                holes = holes.union(Solid(polygons: prism(
                    shape: shapes[i], plane: f.sketch.plane, h0: h0 - ext, h1: h1 + ext,
                    bottomR: bR > 0 ? bR + ext : 0, topR: tR > 0 ? tR + ext : 0,
                    bottomFlare: true, topFlare: true)))
            }
        }
        return body.subtract(holes)
    }

    /// 図形を h0〜h1 まで押し出した柱。端のエッジを半径Rで丸められる。
    /// flare = true のときは丸めの向きが外側(穴の入口を丸めるための道具形状)。
    static func prism(shape: SketchShape, plane: SketchPlane, h0: Double, h1: Double,
                      bottomR: Double, topR: Double, bottomFlare: Bool, topFlare: Bool) -> [CSGPolygon] {
        let height = h1 - h0
        guard height > 1e-9 else { return [] }
        var rb = max(0, bottomR), rt = max(0, topR)
        if rb + rt > height * 0.999 {
            let s = height * 0.999 / (rb + rt)
            rb *= s
            rt *= s
        }
        // 内側へ丸めるときは、形がつぶれない大きさまで小さくする
        if !bottomFlare { rb = limitInset(shape, rb) }
        if !topFlare { rt = limitInset(shape, rt) }

        // 段(高さ, 内側へのずらし量)
        var rings: [(h: Double, inset: Double)] = []
        let steps = filletSteps
        if rb > 1e-6 {
            let sign = bottomFlare ? -1.0 : 1.0
            for k in 0..<steps {
                let phi = Double.pi / 2 * Double(k) / Double(steps)
                rings.append((h0 + rb * (1 - cos(phi)), sign * rb * (1 - sin(phi))))
            }
        }
        rings.append((h0 + rb, 0))
        if height - rb - rt > 1e-6 || rings.count == 1 {
            rings.append((h1 - rt, 0))
        }
        if rt > 1e-6 {
            let sign = topFlare ? -1.0 : 1.0
            for k in 1...steps {
                let phi = Double.pi / 2 * Double(k) / Double(steps)
                rings.append((h1 - rt + rt * sin(phi), sign * rt * (1 - cos(phi))))
            }
        }
        if rings.count < 2 { return [] }

        let loops = rings.map { ring in
            ProfileGeometry.outline(shape, inset: ring.inset).map { plane.point($0, height: ring.h) }
        }
        var polys: [CSGPolygon] = []
        func addTri(_ a: Vec3, _ b: Vec3, _ c: Vec3) {
            if let p = CSGPolygon(vertices: [a, b, c]) { polys.append(p) }
        }
        // 側面
        for k in 0..<(loops.count - 1) {
            let lower = loops[k], upper = loops[k + 1]
            let n = lower.count
            for i in 0..<n {
                let j = (i + 1) % n
                addTri(lower[i], lower[j], upper[j])
                addTri(lower[i], upper[j], upper[i])
            }
        }
        // ふた(両端の面)
        for (index, isTop) in [(0, false), (rings.count - 1, true)] {
            let ring = rings[index]
            let pts2 = Polygon2D.dedupe(ProfileGeometry.outline(shape, inset: ring.inset))
            guard pts2.count >= 3 else { continue }
            let pts3 = pts2.map { plane.point($0, height: ring.h) }
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
