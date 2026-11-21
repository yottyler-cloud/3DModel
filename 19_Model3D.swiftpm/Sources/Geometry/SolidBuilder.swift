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
        /// 計算したソリッド(断面表示に使う)
        var solid = Solid.empty
    }

    static func build(_ features: [Feature]) -> Result {
        // ソリッドボディの一覧(「つなげない」押し出しは別のボディになる)
        var bodies: [Solid] = []
        var messages: [String] = []
        // シェル用: ここまでに作ったフィーチャーと、スケッチ面側がほかの形に接していたか
        var done: [(Feature, Bool)] = []
        for f in effective(features) {
            if f.kind == .shell {
                if bodies.isEmpty {
                    messages.append("「\(f.name)」: シェルにする形がまだありません")
                    continue
                }
                // 計算がうまくいかないときは、厚みをごくわずか変えて(面がちょうど重なるのを避けて)やり直す
                let t = max(f.filletRadius, 0.01)
                var done2: [Solid]?
                var lastMessages: [String] = []
                var why = ""
                for tt in [t, t + 0.0013, t - 0.0011, t + 0.0031] where tt > 0 {
                    var msgs: [String] = []
                    let pieces = shellInner(done, thickness: tt, open: f.filletEdges, messages: &msgs)
                    lastMessages = msgs
                    let r = shell(bodies, pieces: pieces, thickness: tt)
                    if let ok = r.bodies {
                        done2 = ok
                        break
                    }
                    if why.isEmpty { why = r.reason }
                }
                messages += lastMessages
                if let r = done2 {
                    bodies = r
                } else {
                    messages.append("「\(f.name)」: シェルを計算できませんでした [\(why)]")
                }
                continue
            }
            done.append((f, startContact(f, bodies: bodies)))
            let shapes = f.sketch.shapes.filter { $0.isProfile }
            if shapes.isEmpty {
                messages.append("「\(f.name)」: スケッチに閉じた図形がありません")
                continue
            }
            if f.kind.isRevolve {
                // 回転・回転カット
                guard let axis = f.revolveAxis else {
                    messages.append("「\(f.name)」: 回転軸を選んでください(スケッチの線をタップ)")
                    continue
                }
                guard let tool = revolveSolid(for: f, shapes: shapes, axis: axis) else {
                    messages.append("「\(f.name)」: 輪郭が回転軸をまたいでいます。軸の片側にある輪郭にしてください")
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
                    var tool = toolSolid(for: f, shapes: shapes, startConcave: concave)
                    // 付け根のすみRは、下に元の形がある範囲だけにつける(ふちからはみ出さない)
                    if concave { tool = clipRootFillet(tool, f, shapes: shapes, bodies: bodies) }
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
        return Result(mesh: TriMesh(solid: all), messages: messages, bodyCount: bodies.count, solid: all)
    }

    /// 付け根のすみR(外へ広げた部分)のうち、下に元の形がない部分を取り除く
    static func clipRootFillet(_ tool: Solid, _ f: Feature, shapes: [SketchShape], bodies: [Solid]) -> Solid {
        var r: Double = f.startFillet
        for t in f.sideTreatments ?? [] where !t.atEnd { r = Swift.max(r, t.size) }
        guard r > 1e-6, !bodies.isEmpty else { return tool }
        let (h0, h1, atBottom) = extent(of: f)
        let hs: Double = atBottom ? h0 : h1          // スケッチ面(付け根)の高さ
        let dir: Double = atBottom ? 1.0 : -1.0      // 押し出す向き
        let band: Double = r * 1.01
        let plane = f.sketch.plane
        let body = Solid(polygons: bodies.flatMap { $0.polygons })
        var bb = body.bounds
        let tb = tool.bounds
        bb.add(tb.min)
        bb.add(tb.max)
        let big: Double = bb.size.length + 10
        let c = plane.project(bb.center)
        let rect = SketchShape.rectangle(c - Vec2(big, big), c + Vec2(big, big))
        func slab(_ a: Double, _ b: Double) -> Solid {
            Solid(polygons: prism(shape: rect, plane: plane, h0: Swift.min(a, b), h1: Swift.max(a, b), bottom: [], top: []))
        }
        // すみRがある高さの層
        let layer = slab(hs, hs + dir * band)
        // 付け根の面のすぐ下にある元の形を、すみRの高さまで持ち上げたもの(ここにはすみRがあってよい)
        let below = body.intersect(slab(hs - dir * band, hs))
        let support = below.translated(by: plane.normal * (dir * band))
        // ボス自体(すみRなし)はそのまま残す
        var core = Solid.empty
        for s in shapes {
            core = core.union(Solid(polygons: prism(shape: s, plane: plane, h0: Swift.min(hs, hs + dir * band),
                                                    h1: Swift.max(hs, hs + dir * band), bottom: [], top: [])))
        }
        let unsupported = layer.subtract(support).subtract(core)
        return tool.subtract(unsupported)
    }

    /// 押し出しのスケッチ面側(始まりの面)に、ほかの形が接しているか
    static func startTouchesBody(_ f: Feature, bodies: [Solid]) -> Bool {
        let hasStart = f.startFillet > 0 || (f.sideTreatments ?? []).contains { !$0.atEnd && $0.size > 0 }
        return hasStart && startContact(f, bodies: bodies)
    }

    /// 押し出しのスケッチ面側が、ほかの形に接しているか
    static func startContact(_ f: Feature, bodies: [Solid]) -> Bool {
        guard f.kind == .extrude, f.endCondition != .midPlane, !bodies.isEmpty else { return false }
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
        return fs.filter { $0.kind.isSolidFeature || $0.kind == .shell }
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
                      bottom: [EndTreatment], top: [EndTreatment], baseInset: Double = 0,
                      sideBase: [Double]? = nil) -> [CSGPolygon] {
        let height = h1 - h0
        let n = ProfileGeometry.sideCount(shape)
        guard height > 1e-9, n > 0 else { return [] }
        func expand(_ t: [EndTreatment]) -> [EndTreatment] {
            if t.count == 1 { return Array(repeating: t[0], count: n) }
            return (0..<n).map { $0 < t.count ? t[$0] : .none }
        }
        var bot = expand(bottom), tp = expand(top)
        // 辺ごとの基本のずらし量(シェルの開口にした側面は外へ大きく出す)
        func base(_ i: Int) -> Double {
            if let sb = sideBase, i < sb.count { return sb[i] }
            return baseInset
        }

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
                max(bot[i].flare ? 0 : bot[i].size, tp[i].flare ? 0 : tp[i].size) + max(base(i), 0)
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
            (0..<n).map { i in base(i) + profile(bot[i], h - h0) + profile(tp[i], h1 - h) }
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

    // MARK: シェル

    /// シェルでくり抜く形: これまでのフィーチャーを厚みの分だけ内側に縮めて作り直したもの
    /// (押し出し・回転は縮め、カットは広げる)。開口に選んだ面は外まで抜く
    /// くり抜く形でボディをくり抜く。結果の外形が元と変わってしまったら(計算の失敗)、
    /// 1つずつくり抜く方法でやり直し、それでもだめなら元の形のままにする
    static func shell(_ bodies: [Solid], pieces: [(Solid, Bool)], thickness t: Double) -> (bodies: [Solid]?, reason: String) {
        func union(_ ps: [(Solid, Bool)]) -> Solid {
            var s = Solid.empty
            for (p, add) in ps { s = add ? s.union(p) : s.subtract(p) }
            return s
        }
        // 失敗したときの数値(原因を調べるため)
        func describe(_ before: Solid, _ after: Solid) -> String {
            func f(_ v: Double) -> String { String(format: "%.1f", v) }
            let a = before.bounds.size, b = after.bounds.size
            return "部品\(pieces.count) 内\(f(union(pieces).volume)) 前\(f(a.x))×\(f(a.y))×\(f(a.z)) V\(f(before.volume)) 後\(f(b.x))×\(f(b.y))×\(f(b.z)) V\(f(after.volume)) 面\(after.polygons.count)"
        }
        func plausible(_ before: Solid, _ after: Solid) -> Bool {
            guard !after.isEmpty else { return false }
            let a = before.bounds, b = after.bounds
            let tol = max(t * 0.5, 0.05)
            let sizeOK = abs(a.size.x - b.size.x) < tol && abs(a.size.y - b.size.y) < tol && abs(a.size.z - b.size.z) < tol
            let va = before.volume, vb = after.volume
            return sizeOK && vb > 0 && vb < va + 1e-6
        }
        let inner = union(pieces)
        var out: [Solid] = []
        for body in bodies {
            let r1 = body.subtract(inner)
            if plausible(body, r1) {
                out.append(r1)
                continue
            }
            // やり直し: 足す形で1つずつくり抜き、カットのまわりの壁(元の形とカットを広げた形の重なり)を戻す
            var r2 = body
            for (p, add) in pieces where add { r2 = r2.subtract(p) }
            for (p, add) in pieces where !add { r2 = r2.union(body.intersect(p)) }
            if plausible(body, r2) {
                out.append(r2)
            } else {
                return (nil, describe(body, r1))
            }
        }
        return (out.filter { !$0.isEmpty }, "")
    }

    /// シェルでくり抜く形(足す形と、そこから除く形の並び)
    static func shellInner(_ prev: [(Feature, Bool)], thickness t: Double, open: [EdgeRef],
                           messages: inout [String]) -> [(Solid, Bool)] {
        var pieces: [(Solid, Bool)] = []
        let far = t * 3 + 1
        for (f, touch) in prev {
            let shapes = f.sketch.shapes.filter { $0.isProfile }
            guard !shapes.isEmpty else { continue }
            let depth = nestingDepth(shapes)
            let plane = f.sketch.plane
            let (h0, h1, atBottom) = extent(of: f)
            let isMid = f.endCondition == .midPlane
            let bottomIsStart = !isMid && atBottom
            let topIsStart = !isMid && !atBottom
            switch f.kind {
            case .extrude:
                let startOpen = open.contains(.start(f.id)), endOpen = open.contains(.end(f.id))
                // 端をどれだけ外へ延ばすか(負なら縮める)
                func grow(_ isStart: Bool) -> Double {
                    if isStart ? startOpen : endOpen { return far }
                    // ほかの形に接する側: 中の空洞をつなげる(面で接するだけだと計算が不安定なので少し重ねる)
                    if isStart && touch { return t + min(t * 0.5, 1) }
                    return -t
                }
                let hb = h0 - grow(bottomIsStart), ht = h1 + grow(topIsStart)
                guard ht - hb > 1e-6 else { continue }
                for (i, shape) in shapes.enumerated() where depth[i] % 2 == 0 {
                    // 開口にした側面は、その辺を外へ大きく出して壁を抜く
                    let sideBase = (0..<ProfileGeometry.sideCount(shape)).map { k -> Double in
                        open.contains { r in
                            if case .side(let fid, let sid, let kk, _) = r { return fid == f.id && sid == shape.id && kk == k }
                            return false
                        } ? -far : t
                    }
                    guard ProfileGeometry.insetIsValid(shape, sideInsets: sideBase.map { max($0, 0) }) else {
                        messages.append("「\(f.name)」: シェルの厚みが形に対して大きすぎます")
                        continue
                    }
                    // 外側のフィレット・面取りは、厚みの分だけ小さくして内側にもつける
                    func shrunk(_ isStart: Bool, open: Bool) -> [EndTreatment] {
                        if open { return [] }
                        let size = isStart ? f.startFillet : f.endFillet
                        let chamfer = isStart ? (f.startIsChamfer ?? false) : (f.endIsChamfer ?? false)
                        var list = Array(repeating: EndTreatment(size: max(size - t, 0), chamfer: chamfer, flare: false),
                                         count: ProfileGeometry.sideCount(shape))
                        for st in f.sideTreatments ?? [] where st.shapeID == shape.id && st.atEnd == !isStart && st.side < list.count {
                            list[st.side] = EndTreatment(size: max(st.size - t, 0), chamfer: st.chamfer, flare: false)
                        }
                        return list
                    }
                    let bOpen = bottomIsStart ? startOpen || touch : (isMid ? endOpen : endOpen)
                    let tOpen = topIsStart ? startOpen || touch : endOpen
                    var piece = Solid(polygons: prism(shape: shape, plane: plane, h0: hb, h1: ht,
                                                      bottom: shrunk(bottomIsStart, open: bOpen),
                                                      top: shrunk(topIsStart, open: tOpen), baseInset: t,
                                                      sideBase: sideBase))
                    // 形の中の穴: 穴のまわりにも厚みを残す
                    for (j, hole) in shapes.enumerated() where depth[j] % 2 == 1 {
                        piece = piece.subtract(Solid(polygons: prism(shape: hole, plane: plane, h0: hb - 1, h1: ht + 1,
                                                                     bottom: [], top: [], baseInset: -t)))
                    }
                    pieces.append((piece, true))
                }
            case .cut:
                // カットは広げる: 入口は外まで、底は厚みの分だけ深く
                let entryBottom = bottomIsStart, entryTop = topIsStart
                let through = f.endCondition == .throughAll
                let hb = h0 - (entryBottom || through ? far : t)
                let ht = h1 + (entryTop || through ? far : t)
                for (i, shape) in shapes.enumerated() where depth[i] % 2 == 0 {
                    pieces.append((Solid(polygons: prism(shape: shape, plane: plane, h0: hb, h1: ht,
                                                         bottom: [], top: [], baseInset: -t)), false))
                }
            case .revolve, .revolveCut:
                guard let axis = f.revolveAxis else { continue }
                let sign = f.kind == .revolve ? 1.0 : -1.0
                var piece = Solid.empty
                for (i, shape) in shapes.enumerated() where depth[i] % 2 == 0 {
                    // 回転軸の上にある辺はずらさない(中の空洞が軸まで届くように)
                    let insets = (0..<ProfileGeometry.sideCount(shape)).map { k -> Double in
                        if let seg = shape.segment(k), onAxis(seg, axis) { return 0 }
                        return sign * t
                    }
                    if let polys = revolve(shape: shape, feature: f, axis: axis, sideInsets: insets) {
                        piece = piece.union(Solid(polygons: polys))
                    }
                }
                pieces.append((piece, f.kind == .revolve))
            default:
                break
            }
        }
        return pieces
    }

    /// 線分が回転軸の上にあるか
    private static func onAxis(_ seg: (Vec2, Vec2), _ axis: (Vec2, Vec2)) -> Bool {
        let d = (axis.1 - axis.0).normalized
        func dist(_ p: Vec2) -> Double { abs((p - axis.0).cross(d)) }
        return dist(seg.0) < 1e-6 && dist(seg.1) < 1e-6
    }

    static let revolveSegments = 48

    /// 中心線を軸にスケッチを回した形(輪郭が軸をまたぐと nil)
    static func revolveSolid(for f: Feature, shapes: [SketchShape], axis: (Vec2, Vec2)) -> Solid? {
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
    static func revolve(shape: SketchShape, feature f: Feature, axis: (Vec2, Vec2),
                        sideInsets: [Double]? = nil) -> [CSGPolygon]? {
        let plane = f.sketch.plane
        let a = axis.0
        let d = (axis.1 - a).normalized
        var perp = Vec2(-d.y, d.x)
        let pts = Polygon2D.dedupe(sideInsets.map { ProfileGeometry.outline(shape, sideInsets: $0) }
            ?? ProfileGeometry.outline(shape))
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
