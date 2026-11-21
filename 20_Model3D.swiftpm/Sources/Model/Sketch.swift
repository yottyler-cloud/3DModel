import Foundation

/// 基準の3平面(Y が上)
enum RefPlane: String, Codable, CaseIterable, Identifiable {
    case front, top, right
    var id: String { rawValue }

    var label: String {
        switch self {
        case .front: return "正面"
        case .top: return "平面"
        case .right: return "右側面"
        }
    }

    var plane: SketchPlane {
        switch self {
        case .front: return .from(normal: Vec3(0, 0, 1), through: .zero, name: label)
        case .top: return .from(normal: Vec3(0, 1, 0), through: .zero, name: label)
        case .right: return .from(normal: Vec3(1, 0, 0), through: .zero, name: label)
        }
    }
}

/// スケッチを描く平面(原点と、横 u・縦 v の向き。法線は u × v)
struct SketchPlane: Codable, Hashable {
    var origin: Vec3
    var u: Vec3
    var v: Vec3
    var name: String

    var normal: Vec3 { u.cross(v) }

    /// 法線と通る点から平面をつくる。横・縦の向きは、上から見た面なら X と -Z、
    /// それ以外は「上(Y)が縦」になるように決める
    static func from(normal n0: Vec3, through p: Vec3, name: String) -> SketchPlane {
        let n = n0.normalized
        var v: Vec3
        if abs(n.y) > 0.9 {
            v = n.y > 0 ? Vec3(0, 0, -1) : Vec3(0, 0, 1)
        } else {
            v = Vec3(0, 1, 0)
        }
        v = (v - n * v.dot(n)).normalized
        let u = v.cross(n).normalized
        return SketchPlane(origin: n * n.dot(p), u: u, v: v, name: name)
    }

    /// 平面上の2D座標 → 3D(h は法線方向の高さ)
    func point(_ p: Vec2, height h: Double = 0) -> Vec3 {
        origin + u * p.x + v * p.y + normal * h
    }

    /// 3D → 平面上の2D座標
    func project(_ p: Vec3) -> Vec2 {
        let d = p - origin
        return Vec2(d.dot(u), d.dot(v))
    }

    /// 平面からの符号付き距離
    func distance(_ p: Vec3) -> Double { (p - origin).dot(normal) }

    func isCoplanar(with o: SketchPlane) -> Bool {
        normal.dot(o.normal) > 0.9999 && abs(distance(o.origin)) < 1e-5
    }
}

enum ShapeKind: String, Codable {
    case rectangle, circle, polygon, centerline

    var label: String {
        switch self {
        case .rectangle: return "長方形"
        case .circle: return "円"
        case .polygon: return "多角形"
        case .centerline: return "中心線"
        }
    }
}

/// スケッチ上の閉じた図形
struct SketchShape: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ShapeKind
    /// 長方形: 対角の2点 / 円: [中心] / 多角形: 頂点
    var points: [Vec2]
    /// 円の半径
    var radius: Double = 0
    /// 角ごとのフィレット半径(長方形は左下から反時計回りの4つ、多角形は頂点順)
    var cornerRadii: [Double] = []

    static func rectangle(_ a: Vec2, _ b: Vec2) -> SketchShape {
        SketchShape(kind: .rectangle, points: [a, b], cornerRadii: [0, 0, 0, 0])
    }

    static func circle(center: Vec2, radius: Double) -> SketchShape {
        SketchShape(kind: .circle, points: [center], radius: radius)
    }

    static func centerRectangle(center c: Vec2, corner: Vec2) -> SketchShape {
        let d = Vec2(abs(corner.x - c.x), abs(corner.y - c.y))
        return .rectangle(c - d, c + d)
    }

    static func centerline(_ a: Vec2, _ b: Vec2) -> SketchShape {
        SketchShape(kind: .centerline, points: [a, b])
    }

    /// 直線の辺(長方形・多角形の辺 k、中心線は k = 0)。円は nil
    func segment(_ k: Int) -> (Vec2, Vec2)? {
        switch kind {
        case .centerline:
            return isValid ? (points[0], points[1]) : nil
        case .rectangle, .polygon:
            let c = corners
            guard k >= 0, k < c.count else { return nil }
            return (c[k], c[(k + 1) % c.count])
        case .circle:
            return nil
        }
    }

    /// 直線の辺の数
    var segmentCount: Int {
        switch kind {
        case .centerline: return 1
        case .rectangle, .polygon: return corners.count
        case .circle: return 0
        }
    }

    /// 押し出し・回転に使う閉じた輪郭か(中心線は輪郭ではない)
    var isProfile: Bool { kind != .centerline && isValid }

    static func polygon(_ pts: [Vec2]) -> SketchShape {
        SketchShape(kind: .polygon, points: pts, cornerRadii: Array(repeating: 0, count: pts.count))
    }

    // MARK: 長方形の数値

    var rectMin: Vec2 {
        Vec2(min(points[0].x, points[1].x), min(points[0].y, points[1].y))
    }
    var rectSize: Vec2 {
        Vec2(abs(points[1].x - points[0].x), abs(points[1].y - points[0].y))
    }
    mutating func setRect(origin: Vec2, size: Vec2) {
        points = [origin, origin + Vec2(max(size.x, 0.001), max(size.y, 0.001))]
    }

    /// 角になる頂点(円は空)。編集やスナップの基準に使う
    var corners: [Vec2] {
        switch kind {
        case .rectangle:
            let a = rectMin, s = rectSize
            return [a, a + Vec2(s.x, 0), a + s, a + Vec2(0, s.y)]
        case .circle, .centerline:
            return []
        case .polygon:
            return points
        }
    }

    /// スナップ用の点
    var snapPoints: [Vec2] {
        switch kind {
        case .circle:
            let c = points[0]
            return [c, c + Vec2(radius, 0), c + Vec2(-radius, 0), c + Vec2(0, radius), c + Vec2(0, -radius)]
        case .centerline:
            return points
        default:
            return corners
        }
    }

    var isValid: Bool {
        switch kind {
        case .rectangle: return points.count == 2 && rectSize.x > 1e-6 && rectSize.y > 1e-6
        case .circle: return points.count == 1 && radius > 1e-6
        case .polygon: return points.count >= 3 && abs(Polygon2D.signedArea(points)) > 1e-9
        case .centerline: return points.count == 2 && points[0].distance(to: points[1]) > 1e-6
        }
    }

    mutating func translate(by d: Vec2) {
        points = points.map { $0 + d }
    }

    func radius(at i: Int) -> Double {
        i < cornerRadii.count ? cornerRadii[i] : 0
    }

    mutating func setRadius(_ r: Double, at i: Int) {
        let n = corners.count
        if cornerRadii.count < n { cornerRadii += Array(repeating: 0, count: n - cornerRadii.count) }
        if i < n {
            cornerRadii[i] = max(0, r)
            if r > 0 { setChamferValue(0, at: i) }
        }
    }

    mutating func setAllRadii(_ r: Double) {
        cornerRadii = Array(repeating: max(0, r), count: corners.count)
        if r > 0 { cornerChamfers = nil }
    }

    // MARK: 角の面取り(C)。R と C は同じ角に同時にはつかない

    /// 角ごとの面取りの長さ(古い保存データには無いので省略可)
    var cornerChamfers: [Double]?

    func chamfer(at i: Int) -> Double {
        guard let c = cornerChamfers, i < c.count else { return 0 }
        return c[i]
    }

    private mutating func setChamferValue(_ c: Double, at i: Int) {
        let n = corners.count
        var list = cornerChamfers ?? []
        if list.count < n { list += Array(repeating: 0, count: n - list.count) }
        if i < n { list[i] = max(0, c) }
        cornerChamfers = list
    }

    mutating func setChamfer(_ c: Double, at i: Int) {
        setChamferValue(c, at: i)
        if c > 0, i < cornerRadii.count { cornerRadii[i] = 0 }
    }

    mutating func setAllChamfers(_ c: Double) {
        cornerChamfers = Array(repeating: max(0, c), count: corners.count)
        if c > 0 { cornerRadii = Array(repeating: 0, count: corners.count) }
    }
}

/// 図形を点列(輪郭)にする計算
enum ProfileGeometry {
    static let circleSegments = 48
    static let arcSegments = 6

    /// 反時計回りに並べた角と、その角のR・C。sideOf[j] は反時計回りの辺 j が図形の何番目の辺か
    /// (図形の辺 k は corners[k] → corners[k+1])
    static func ccwCorners(_ shape: SketchShape) -> (pts: [Vec2], radii: [Double], chamfers: [Double], sideOf: [Int]) {
        var pts = shape.corners
        var radii = (0..<pts.count).map { shape.radius(at: $0) }
        var chamfers = (0..<pts.count).map { shape.chamfer(at: $0) }
        let n = pts.count
        var sideOf = Array(0..<n)
        if Polygon2D.signedArea(pts) < 0 {
            pts.reverse()
            radii.reverse()
            chamfers.reverse()
            sideOf = (0..<n).map { j in ((n - 2 - j) % n + n) % n }
        }
        return (pts, radii, chamfers, sideOf)
    }

    /// 図形の辺の数(円は1つの辺として扱う)
    static func sideCount(_ shape: SketchShape) -> Int {
        switch shape.kind {
        case .circle: return 1
        case .centerline: return 0
        case .rectangle, .polygon: return shape.corners.count
        }
    }

    /// 図形の輪郭(反時計回り)。inset > 0 なら内側へ、< 0 なら外側へずらした輪郭。
    static func outline(_ shape: SketchShape, inset: Double = 0) -> [Vec2] {
        outline(shape, sideInsets: Array(repeating: inset, count: max(sideCount(shape), 1)))
    }

    /// 辺ごとに違う量だけずらした輪郭(sideInsets は図形の辺の番号順)。
    /// 同じ図形なら、ずらす量にかかわらず点の数が同じになる(押し出しの側面をつなぐため)。
    static func outline(_ shape: SketchShape, sideInsets: [Double]) -> [Vec2] {
        func inset(_ k: Int) -> Double { k < sideInsets.count ? sideInsets[k] : 0 }
        switch shape.kind {
        case .centerline:
            return shape.points
        case .circle:
            let c = shape.points[0]
            let r = max(shape.radius - inset(0), 1e-4)
            return (0..<circleSegments).map { i in
                let a = Double(i) / Double(circleSegments) * 2 * Double.pi
                return c + Vec2(cos(a), sin(a)) * r
            }
        case .rectangle, .polygon:
            let (base, radii, chamfers, sideOf) = ccwCorners(shape)
            let n = base.count
            let o = (0..<n).map { inset(sideOf[$0]) }
            let pts = offsetPolygon(base, o)
            var out: [Vec2] = []
            out.reserveCapacity(n * (arcSegments + 1))
            for i in 0..<n {
                let prev = pts[(i + n - 1) % n], p = pts[i], next = pts[(i + 1) % n]
                let convex = (p - prev).cross(next - p) > 0
                let iPrev = (i + n - 1) % n, iNext = (i + 1) % n
                let shareA = radii[iPrev] > 0 || chamfers[iPrev] > 0 ? 0.5 : 1.0
                let shareB = radii[iNext] > 0 || chamfers[iNext] > 0 ? 0.5 : 1.0
                // 角の面(面取り・R)のずらし量: 2辺とも同じ向きにずらすときだけ、小さいほうに合わせる。
                // 片側の辺だけなら角の面はそのまま残り、辺の面取りは角の面にぶつかって止まる
                let oa = o[iPrev], ob = o[i]
                let d: Double = oa * ob > 0 ? (abs(oa) < abs(ob) ? oa : ob) : 0
                if chamfers[i] > 0 && radii[i] <= 0 {
                    // 面取りの角: 元の角の面の直線をずらし、ずらした2辺との交点を端にする
                    let bp = base[i], bPrev = base[iPrev], bNext = base[iNext]
                    let la = (bPrev - bp).length, lb = (bNext - bp).length
                    let t = min(chamfers[i], min(la * shareA, lb * shareB) * 0.999)
                    if t > 1e-9 {
                        let t1 = bp + (bPrev - bp).normalized * t
                        let t2 = bp + (bNext - bp).normalized * t
                        let na = (bp - bPrev).normalized.perp
                        let nb = (bNext - bp).normalized.perp
                        let nf = (t2 - t1).normalized.perp
                        // ずらす量が面取りより大きいと、面取りの線が角の外側へ裏返る(輪郭がねじれる)。
                        // そのときは面取りが消えたものとして、ふつうの角にする
                        if let q1 = intersect(na, na.dot(bp) + oa, nf, nf.dot(t1) + d),
                           let q2 = intersect(nf, nf.dot(t1) + d, nb, nb.dot(bp) + ob),
                           (q1 - p).dot(prev - p) > 1e-9, (q2 - p).dot(next - p) > 1e-9 {
                            let count = arcSegments + 1
                            out.append(contentsOf: (0..<count).map { q1 + (q2 - q1) * (Double($0) / Double(count - 1)) })
                            continue
                        }
                    }
                    out.append(contentsOf: chamferCorner(prev: prev, p: p, next: next, setback: 0,
                                                         shareA: shareA, shareB: shareB))
                    continue
                }
                var r = radii[i]
                if r > 0 || !convex {
                    // 内側へずらすと、凸の角のRは小さく、凹の角のRは大きくなる
                    r = convex ? max(r - d, 0) : max(r + d, 0)
                }
                out.append(contentsOf: corner(prev: prev, p: p, next: next, radius: r,
                                              shareA: shareA, shareB: shareB))
            }
            return out
        }
    }

    /// 2直線 n1·x = c1, n2·x = c2 の交点
    static func intersect(_ n1: Vec2, _ c1: Double, _ n2: Vec2, _ c2: Double) -> Vec2? {
        let det = n1.x * n2.y - n1.y * n2.x
        guard abs(det) > 1e-9 else { return nil }
        return Vec2((c1 * n2.y - n1.y * c2) / det, (n1.x * c2 - c1 * n2.x) / det)
    }

    /// 反時計回りの多角形の各辺を、辺ごとの量だけ内側へずらした多角形(角は2辺の交点)。
    /// o[j] は辺 j(点 j → 点 j+1)のずらし量
    static func offsetPolygon(_ pts: [Vec2], _ o: [Double]) -> [Vec2] {
        let n = pts.count
        guard n >= 3 else { return pts }
        if o.allSatisfy({ abs($0) < 1e-12 }) { return pts }
        return (0..<n).map { j in
            let ia = (j + n - 1) % n
            let na = (pts[j] - pts[ia]).normalized.perp
            let nb = (pts[(j + 1) % n] - pts[j]).normalized.perp
            let ca = na.dot(pts[j]) + o[ia]
            let cb = nb.dot(pts[j]) + o[j]
            let det = na.x * nb.y - na.y * nb.x
            if abs(det) < 0.2 {
                // ほぼ一直線(または鋭すぎる角): 二等分線の向きへずらす
                var m = (na + nb).normalized
                if m.length < 0.5 { m = na }
                let c = max(0.25, m.dot(na))
                return pts[j] + m * (((o[ia] + o[j]) / 2) / c)
            }
            return Vec2((ca * nb.y - na.y * cb) / det, (na.x * cb - ca * nb.x) / det)
        }
    }

    /// 1つの角を面取りした点列(常に arcSegments+1 個、直線上に並ぶ)
    static func chamferCorner(prev: Vec2, p: Vec2, next: Vec2, setback: Double,
                              shareA: Double, shareB: Double) -> [Vec2] {
        let count = arcSegments + 1
        let la = (prev - p).length, lb = (next - p).length
        guard setback > 1e-9, la > 1e-9, lb > 1e-9 else { return Array(repeating: p, count: count) }
        let t = min(setback, min(la * shareA, lb * shareB) * 0.999)
        let t1 = p + (prev - p).normalized * t
        let t2 = p + (next - p).normalized * t
        return (0..<count).map { t1 + (t2 - t1) * (Double($0) / Double(count - 1)) }
    }

    /// 1つの角を丸めた点列(常に arcSegments+1 個)
    static func corner(prev: Vec2, p: Vec2, next: Vec2, radius: Double,
                       shareA: Double, shareB: Double) -> [Vec2] {
        let count = arcSegments + 1
        let la = (prev - p).length, lb = (next - p).length
        let d1 = (prev - p).normalized, d2 = (next - p).normalized
        let cosT = max(-1, min(1, d1.dot(d2)))
        let theta = acos(cosT)
        guard radius > 1e-9, la > 1e-9, lb > 1e-9,
              theta > 1e-3, theta < Double.pi - 1e-3 else {
            return Array(repeating: p, count: count)
        }
        var r = radius
        var t = r / tan(theta / 2)
        let maxT = min(la * shareA, lb * shareB) * 0.999
        if t > maxT {
            t = maxT
            r = t * tan(theta / 2)
        }
        let t1 = p + d1 * t
        let t2 = p + d2 * t
        let bis = (d1 + d2).normalized
        let c = p + bis * (r / sin(theta / 2))
        let a1 = atan2(t1.y - c.y, t1.x - c.x)
        let a2 = atan2(t2.y - c.y, t2.x - c.x)
        var sweep = a2 - a1
        while sweep > Double.pi { sweep -= 2 * Double.pi }
        while sweep < -Double.pi { sweep += 2 * Double.pi }
        return (0..<count).map { i in
            let a = a1 + sweep * Double(i) / Double(count - 1)
            return c + Vec2(cos(a), sin(a)) * r
        }
    }

    /// 辺ごとにずらしても形がつぶれないか
    static func insetIsValid(_ shape: SketchShape, sideInsets: [Double]) -> Bool {
        switch shape.kind {
        case .circle:
            return shape.radius - (sideInsets.first ?? 0) > 1e-3
        case .centerline:
            return true
        case .rectangle, .polygon:
            let (base, _, _, sideOf) = ccwCorners(shape)
            let o = (0..<base.count).map { sideOf[$0] < sideInsets.count ? sideInsets[sideOf[$0]] : 0 }
            return Polygon2D.offsetIsValid(base, offsetPolygon(base, o))
        }
    }

    /// 内側へ inset ずらしても形がつぶれないか
    static func insetIsValid(_ shape: SketchShape, inset: Double) -> Bool {
        switch shape.kind {
        case .circle:
            return shape.radius - inset > 1e-3
        case .centerline:
            return true
        case .rectangle, .polygon:
            return insetIsValid(shape, sideInsets: Array(repeating: inset, count: sideCount(shape)))
        }
    }
}

struct Sketch: Codable, Hashable {
    var plane = RefPlane.top.plane
    var shapes: [SketchShape] = []
    /// 寸法(dims で読み書きする)
    var dimensions: [SketchDimension]?
}
