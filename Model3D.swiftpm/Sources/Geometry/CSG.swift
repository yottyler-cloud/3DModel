import Foundation

// BSPツリーによるソリッドのブーリアン演算(和・差)。
// csg.js (Evan Wallace, MIT) のアルゴリズムを Swift に移植し、
// 深い再帰でスタックがあふれないよう、ツリーの走査はすべてループで書いている。

struct CSGPlane {
    var normal: Vec3
    var w: Double

    static let epsilon = 1e-5

    /// Newell 法で多角形の平面を求める(3点が一直線上でも安定)
    init?(points: [Vec3]) {
        guard points.count >= 3 else { return nil }
        var n = Vec3.zero
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
        }
        let len = n.length
        guard len > 1e-12 else { return nil }
        normal = n / len
        var c = Vec3.zero
        for p in points { c = c + p }
        c = c / Double(points.count)
        w = normal.dot(c)
    }

    mutating func flip() {
        normal = -normal
        w = -w
    }

    enum Side { case coplanarFront, coplanarBack, front, back }

    /// 多角形をこの平面で分割し、どちら側に属するかを emit で返す
    func split(_ polygon: CSGPolygon, _ emit: (Side, CSGPolygon) -> Void) {
        let coplanar = 0, frontBit = 1, backBit = 2, spanning = 3
        var polygonType = 0
        var types: [Int] = []
        types.reserveCapacity(polygon.vertices.count)
        for v in polygon.vertices {
            let t = normal.dot(v) - w
            let type = t < -CSGPlane.epsilon ? backBit : (t > CSGPlane.epsilon ? frontBit : coplanar)
            polygonType |= type
            types.append(type)
        }
        switch polygonType {
        case coplanar:
            emit(normal.dot(polygon.plane.normal) > 0 ? .coplanarFront : .coplanarBack, polygon)
        case frontBit:
            emit(.front, polygon)
        case backBit:
            emit(.back, polygon)
        default:
            var f: [Vec3] = []
            var b: [Vec3] = []
            let n = polygon.vertices.count
            for i in 0..<n {
                let j = (i + 1) % n
                let ti = types[i], tj = types[j]
                let vi = polygon.vertices[i], vj = polygon.vertices[j]
                if ti != backBit { f.append(vi) }
                if ti != frontBit { b.append(vi) }
                if (ti | tj) == spanning {
                    let t = (w - normal.dot(vi)) / normal.dot(vj - vi)
                    let v = vi.lerp(vj, t)
                    f.append(v)
                    b.append(v)
                }
            }
            if f.count >= 3 { emit(.front, CSGPolygon(vertices: f, plane: polygon.plane)) }
            if b.count >= 3 { emit(.back, CSGPolygon(vertices: b, plane: polygon.plane)) }
        }
    }
}

/// 凸な平面多角形
struct CSGPolygon {
    var vertices: [Vec3]
    var plane: CSGPlane

    init(vertices: [Vec3], plane: CSGPlane) {
        self.vertices = vertices
        self.plane = plane
    }

    init?(vertices: [Vec3]) {
        guard let plane = CSGPlane(points: vertices) else { return nil }
        self.vertices = vertices
        self.plane = plane
    }

    func flipped() -> CSGPolygon {
        var p = self
        p.vertices.reverse()
        p.plane.flip()
        return p
    }
}

final class CSGNode {
    var plane: CSGPlane?
    var front: CSGNode?
    var back: CSGNode?
    var polygons: [CSGPolygon] = []

    init(_ polygons: [CSGPolygon] = []) {
        build(polygons)
    }

    /// このノード以下のすべてのノード
    func allNodes() -> [CSGNode] {
        var result: [CSGNode] = []
        var stack: [CSGNode] = [self]
        while let n = stack.popLast() {
            result.append(n)
            if let f = n.front { stack.append(f) }
            if let b = n.back { stack.append(b) }
        }
        return result
    }

    /// 内外を反転
    func invert() {
        for n in allNodes() {
            n.polygons = n.polygons.map { $0.flipped() }
            n.plane?.flip()
            let t = n.front
            n.front = n.back
            n.back = t
        }
    }

    /// このツリーの内側にある部分を取り除いた多角形を返す
    func clipPolygons(_ input: [CSGPolygon]) -> [CSGPolygon] {
        var result: [CSGPolygon] = []
        var stack: [(CSGNode, [CSGPolygon])] = [(self, input)]
        while let item = stack.popLast() {
            let (node, polys) = item
            guard let plane = node.plane else {
                result.append(contentsOf: polys)
                continue
            }
            var f: [CSGPolygon] = []
            var b: [CSGPolygon] = []
            for p in polys {
                plane.split(p) { side, q in
                    switch side {
                    case .coplanarFront, .front: f.append(q)
                    case .coplanarBack, .back: b.append(q)
                    }
                }
            }
            if !f.isEmpty {
                if let front = node.front { stack.append((front, f)) } else { result.append(contentsOf: f) }
            }
            if !b.isEmpty, let back = node.back {
                stack.append((back, b))
            }
            // back が無い場合、裏側の多角形は内側なので捨てる
        }
        return result
    }

    /// bsp の内側にある多角形をすべて取り除く
    func clipTo(_ bsp: CSGNode) {
        for n in allNodes() {
            n.polygons = bsp.clipPolygons(n.polygons)
        }
    }

    func allPolygons() -> [CSGPolygon] {
        allNodes().flatMap { $0.polygons }
    }

    func build(_ input: [CSGPolygon]) {
        guard !input.isEmpty else { return }
        var stack: [(CSGNode, [CSGPolygon])] = [(self, input)]
        while let item = stack.popLast() {
            let (node, polys) = item
            guard !polys.isEmpty else { continue }
            if node.plane == nil { node.plane = polys[polys.count / 2].plane }
            let plane = node.plane!
            var coplanar = node.polygons
            var f: [CSGPolygon] = []
            var b: [CSGPolygon] = []
            for p in polys {
                plane.split(p) { side, q in
                    switch side {
                    case .coplanarFront, .coplanarBack: coplanar.append(q)
                    case .front: f.append(q)
                    case .back: b.append(q)
                    }
                }
            }
            node.polygons = coplanar
            if !f.isEmpty {
                let n = node.front ?? CSGNode()
                node.front = n
                stack.append((n, f))
            }
            if !b.isEmpty {
                let n = node.back ?? CSGNode()
                node.back = n
                stack.append((n, b))
            }
        }
    }
}

/// 多角形の集まりで表したソリッド
struct Solid {
    var polygons: [CSGPolygon] = []

    static let empty = Solid()

    var isEmpty: Bool { polygons.isEmpty }

    var bounds: Box3 {
        var b = Box3()
        for p in polygons { for v in p.vertices { b.add(v) } }
        return b
    }

    func union(_ other: Solid) -> Solid {
        if isEmpty { return other }
        if other.isEmpty { return self }
        if !bounds.intersects(other.bounds) {
            return Solid(polygons: polygons + other.polygons)
        }
        let a = CSGNode(polygons)
        let b = CSGNode(other.polygons)
        a.clipTo(b)
        b.clipTo(a)
        b.invert()
        b.clipTo(a)
        b.invert()
        a.build(b.allPolygons())
        return Solid(polygons: a.allPolygons())
    }

    /// 共通部分
    func intersect(_ other: Solid) -> Solid {
        if isEmpty || other.isEmpty { return .empty }
        if !bounds.intersects(other.bounds) { return .empty }
        let a = CSGNode(polygons)
        let b = CSGNode(other.polygons)
        a.invert()
        b.clipTo(a)
        b.invert()
        a.clipTo(b)
        b.clipTo(a)
        a.build(b.allPolygons())
        a.invert()
        return Solid(polygons: a.allPolygons())
    }

    /// 体積(多角形の向きが外向きなら正)
    var volume: Double {
        var v = 0.0
        for p in polygons where p.vertices.count >= 3 {
            let a = p.vertices[0]
            for k in 1..<(p.vertices.count - 1) {
                v += a.dot(p.vertices[k].cross(p.vertices[k + 1]))
            }
        }
        return v / 6
    }

    func subtract(_ other: Solid) -> Solid {
        if isEmpty || other.isEmpty { return self }
        if !bounds.intersects(other.bounds) { return self }
        let a = CSGNode(polygons)
        let b = CSGNode(other.polygons)
        a.invert()
        a.clipTo(b)
        b.clipTo(a)
        b.invert()
        b.clipTo(a)
        b.invert()
        a.build(b.allPolygons())
        a.invert()
        return Solid(polygons: a.allPolygons())
    }
}
