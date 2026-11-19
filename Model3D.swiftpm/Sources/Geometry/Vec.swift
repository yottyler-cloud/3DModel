import Foundation

/// 2次元ベクトル(スケッチ平面上の座標, 単位mm)
struct Vec2: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = Vec2(0, 0)

    static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    func dot(_ b: Vec2) -> Double { x * b.x + y * b.y }
    /// 外積のz成分
    func cross(_ b: Vec2) -> Double { x * b.y - y * b.x }
    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: Vec2 {
        let l = length
        return l > 1e-12 ? self / l : Vec2(0, 0)
    }
    /// 左向きの垂直ベクトル
    var perp: Vec2 { Vec2(-y, x) }
    func distance(to b: Vec2) -> Double { (self - b).length }
}

/// 3次元ベクトル(モデル座標, Y が上, 単位mm)
struct Vec3: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var normalized: Vec3 {
        let l = length
        return l > 1e-15 ? self / l : Vec3(0, 0, 0)
    }
    func lerp(_ b: Vec3, _ t: Double) -> Vec3 { self + (b - self) * t }
}

/// 軸平行の境界ボックス
struct Box3 {
    var min = Vec3(.infinity, .infinity, .infinity)
    var max = Vec3(-.infinity, -.infinity, -.infinity)

    var isEmpty: Bool { min.x > max.x }

    mutating func add(_ p: Vec3) {
        min = Vec3(Swift.min(min.x, p.x), Swift.min(min.y, p.y), Swift.min(min.z, p.z))
        max = Vec3(Swift.max(max.x, p.x), Swift.max(max.y, p.y), Swift.max(max.z, p.z))
    }

    func intersects(_ b: Box3, margin: Double = 1e-6) -> Bool {
        if isEmpty || b.isEmpty { return false }
        return min.x <= b.max.x + margin && max.x >= b.min.x - margin
            && min.y <= b.max.y + margin && max.y >= b.min.y - margin
            && min.z <= b.max.z + margin && max.z >= b.min.z - margin
    }

    var center: Vec3 { (min + max) * 0.5 }
    var size: Vec3 { max - min }
}
