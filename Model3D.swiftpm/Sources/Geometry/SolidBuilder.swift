import Foundation

/// 特徴(Feature)の履歴からソリッドをつくる
enum SolidBuilder {
    /// フィレット部分の段数
    static let filletSteps = 6
    static let throughAllDistance = 10_000.0

    struct Result {
        var mesh: TriMesh
        var messages: [String]
    }

    static func build(_ features: [Feature]) -> Result {
        var solid = Solid.empty
        var messages: [String] = []
        for f in features where !f.suppressed {
            let shapes = f.sketch.shapes.filter { $0.isValid }
            if shapes.isEmpty {
                messages.append("「\(f.name)」: スケッチに閉じた図形がありません")
                continue
            }
            let tool = toolSolid(for: f, shapes: shapes)
            switch f.kind {
            case .extrude: solid = solid.union(tool)
            case .cut: solid = solid.subtract(tool)
            }
        }
        return Result(mesh: TriMesh(solid: solid), messages: messages)
    }

    /// 押し出し・引き抜きの範囲(スケッチ面からの高さ)
    static func extent(of f: Feature) -> (h0: Double, h1: Double, sketchAtBottom: Bool) {
        let d = (f.kind == .cut && f.throughAll) ? throughAllDistance : max(f.distance, 0.001)
        switch f.direction {
        case .normal: return (0, d, true)
        case .reverse: return (-d, 0, false)
        case .symmetric: return (-d / 2, d / 2, true)
        }
    }

    /// その特徴が足す(または削る)形
    static func toolSolid(for f: Feature, shapes: [SketchShape]) -> Solid {
        // 何重に囲まれているかで「外形」か「穴」かを決める(偶数: 外形, 奇数: 穴)
        let outlines = shapes.map { ProfileGeometry.outline($0) }
        var depth = Array(repeating: 0, count: shapes.count)
        for i in shapes.indices {
            let p = Polygon2D.interiorPoint(outlines[i])
            for j in shapes.indices where j != i {
                if Polygon2D.contains(outlines[j], p) { depth[i] += 1 }
            }
        }

        let (h0, h1, sketchAtBottom) = extent(of: f)
        // フィレットを下端(h0)・上端(h1)へ割り当てる
        let startR = f.startFillet, endR = f.endFillet
        var bottomR = sketchAtBottom ? startR : endR
        var topR = sketchAtBottom ? endR : startR
        if f.direction == .symmetric {
            // 両側対称のときは両端とも「先端」
            bottomR = endR
            topR = endR
        }
        // 引き抜き: スケッチ面側(入口)のエッジは凸 → 道具を外へ広げる。先端(底)は道具を内へ丸める
        let isCut = f.kind == .cut
        let bottomIsEntry = isCut && sketchAtBottom && f.direction != .symmetric
        let topIsEntry = isCut && !sketchAtBottom
        let throughAll = isCut && f.throughAll

        var body = Solid.empty
        var holes = Solid.empty
        for i in shapes.indices {
            let isOuter = depth[i] % 2 == 0
            if isOuter {
                // 外形
                let bFlare = isCut ? bottomIsEntry : false
                let tFlare = isCut ? topIsEntry : false
                var bR = bottomR, tR = topR
                if throughAll {
                    // 貫通する側の先端は丸めない
                    if !bottomIsEntry { bR = 0 }
                    if !topIsEntry { tR = 0 }
                }
                body = body.union(Solid(polygons: prism(
                    shape: shapes[i], plane: f.sketch.plane, h0: h0, h1: h1,
                    bottomR: bR, topR: tR, bottomFlare: bFlare, topFlare: tFlare)))
            } else {
                // 穴(押し出しの中の穴は外へ広げて、入口のエッジを丸める)
                let ext = 0.01
                if isCut {
                    holes = holes.union(Solid(polygons: prism(
                        shape: shapes[i], plane: f.sketch.plane, h0: h0 - ext, h1: h1 + ext,
                        bottomR: 0, topR: 0, bottomFlare: false, topFlare: false)))
                } else {
                    holes = holes.union(Solid(polygons: prism(
                        shape: shapes[i], plane: f.sketch.plane, h0: h0 - ext, h1: h1 + ext,
                        bottomR: bottomR > 0 ? bottomR + ext : 0, topR: topR > 0 ? topR + ext : 0,
                        bottomFlare: true, topFlare: true)))
                }
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
        // ふた(上下の面)
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

/// 描画・書き出し用の三角形メッシュ(3頂点ずつ)
struct TriMesh {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    var bounds = Box3()

    var triangleCount: Int { positions.count / 3 }

    init() {}

    init(solid: Solid) {
        var tris: [(Vec3, Vec3, Vec3)] = []
        for p in solid.polygons where p.vertices.count >= 3 {
            for k in 1..<(p.vertices.count - 1) {
                tris.append((p.vertices[0], p.vertices[k], p.vertices[k + 1]))
            }
        }
        // 面の法線と面積
        var faceN: [Vec3] = []
        var keep: [(Vec3, Vec3, Vec3)] = []
        for t in tris {
            let c = (t.1 - t.0).cross(t.2 - t.0)
            if c.length < 1e-12 { continue }
            keep.append(t)
            faceN.append(c) // 長さ = 面積×2(面積の重み)
        }
        // 同じ位置の頂点を集めて、なめらかな面は法線を平均する(角度40°以上は折れ目)
        let q = 1e-4
        func key(_ v: Vec3) -> SIMD3<Int64> {
            SIMD3(Int64((v.x / q).rounded()), Int64((v.y / q).rounded()), Int64((v.z / q).rounded()))
        }
        var groups: [SIMD3<Int64>: [Int]] = [:]
        for (i, t) in keep.enumerated() {
            groups[key(t.0), default: []].append(i)
            groups[key(t.1), default: []].append(i)
            groups[key(t.2), default: []].append(i)
        }
        let crease = cos(40.0 * Double.pi / 180)
        positions.reserveCapacity(keep.count * 3)
        normals.reserveCapacity(keep.count * 3)
        for (i, t) in keep.enumerated() {
            let ni = faceN[i].normalized
            for v in [t.0, t.1, t.2] {
                var sum = Vec3.zero
                for j in groups[key(v)] ?? [] {
                    if faceN[j].normalized.dot(ni) >= crease { sum = sum + faceN[j] }
                }
                let n = sum.length > 0 ? sum.normalized : ni
                positions.append(v)
                normals.append(n)
                bounds.add(v)
            }
        }
    }
}
