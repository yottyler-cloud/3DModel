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
    case rectangle, circle, polygon

    var label: String {
        switch self {
        case .rectangle: return "長方形"
        case .circle: return "円"
        case .polygon: return "多角形"
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
        case .circle:
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
        default:
            return corners
        }
    }

    var isValid: Bool {
        switch kind {
        case .rectangle: return points.count == 2 && rectSize.x > 1e-6 && rectSize.y > 1e-6
        case .circle: return points.count == 1 && radius > 1e-6
        case .polygon: return points.count >= 3 && abs(Polygon2D.signedArea(points)) > 1e-9
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
        if i < n { cornerRadii[i] = max(0, r) }
    }

    mutating func setAllRadii(_ r: Double) {
        cornerRadii = Array(repeating: max(0, r), count: corners.count)
    }
}

/// 図形を点列(輪郭)にする計算
enum ProfileGeometry {
    static let circleSegments = 48
    static let arcSegments = 6

    /// 反時計回りに並べた角と、その角のR
    static func ccwCorners(_ shape: SketchShape) -> (pts: [Vec2], radii: [Double]) {
        var pts = shape.corners
        var radii = (0..<pts.count).map { shape.radius(at: $0) }
        if Polygon2D.signedArea(pts) < 0 {
            pts.reverse()
            radii.reverse()
        }
        return (pts, radii)
    }

    /// 図形の輪郭(反時計回り)。inset > 0 なら内側へ、< 0 なら外側へずらした輪郭。
    /// 同じ図形なら inset の値にかかわらず点の数が同じになる(押し出しの側面をつなぐため)。
    static func outline(_ shape: SketchShape, inset: Double = 0) -> [Vec2] {
        switch shape.kind {
        case .circle:
            let c = shape.points[0]
            let r = max(shape.radius - inset, 1e-4)
            return (0..<circleSegments).map { i in
                let a = Double(i) / Double(circleSegments) * 2 * Double.pi
                return c + Vec2(cos(a), sin(a)) * r
            }
        case .rectangle, .polygon:
            let (base, radii) = ccwCorners(shape)
            let pts = Polygon2D.offset(base, by: inset)
            let n = pts.count
            var out: [Vec2] = []
            out.reserveCapacity(n * (arcSegments + 1))
            for i in 0..<n {
                let prev = pts[(i + n - 1) % n], p = pts[i], next = pts[(i + 1) % n]
                let convex = (p - prev).cross(next - p) > 0
                var r = radii[i]
                if r > 0 || !convex {
                    // 内側へずらすと、凸の角のRは小さく、凹の角のRは大きくなる
                    r = convex ? max(r - inset, 0) : max(r + inset, 0)
                }
                let rPrev = radii[(i + n - 1) % n] > 0 ? 0.5 : 1.0
                let rNext = radii[(i + 1) % n] > 0 ? 0.5 : 1.0
                out.append(contentsOf: corner(prev: prev, p: p, next: next, radius: r,
                                              shareA: rPrev, shareB: rNext))
            }
            return out
        }
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

    /// 内側へ inset ずらしても形がつぶれないか
    static func insetIsValid(_ shape: SketchShape, inset: Double) -> Bool {
        switch shape.kind {
        case .circle:
            return shape.radius - inset > 1e-3
        case .rectangle, .polygon:
            let base = ccwCorners(shape).pts
            return Polygon2D.offsetIsValid(base, Polygon2D.offset(base, by: inset))
        }
    }
}

struct Sketch: Codable, Hashable {
    var plane = RefPlane.top.plane
    var shapes: [SketchShape] = []
}
