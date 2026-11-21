import Foundation

/// 2次元の閉じた多角形(点列)に関する計算
enum Polygon2D {
    /// 符号付き面積(反時計回りで正)
    static func signedArea(_ pts: [Vec2]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<pts.count {
            a += pts[i].cross(pts[(i + 1) % pts.count])
        }
        return a * 0.5
    }

    /// 連続する重複点(ほぼ同じ点)を取り除く
    static func dedupe(_ pts: [Vec2], tolerance: Double = 1e-7) -> [Vec2] {
        var out: [Vec2] = []
        for p in pts {
            if let last = out.last, last.distance(to: p) < tolerance { continue }
            out.append(p)
        }
        while out.count > 1, out[0].distance(to: out[out.count - 1]) < tolerance {
            out.removeLast()
        }
        return out
    }

    static func contains(_ pts: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// 点から多角形の輪郭までの最短距離
    static func distanceToOutline(_ pts: [Vec2], _ p: Vec2) -> Double {
        var best = Double.infinity
        for i in 0..<pts.count {
            best = min(best, distanceToSegment(p, pts[i], pts[(i + 1) % pts.count]))
        }
        return best
    }

    static func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let l2 = ab.dot(ab)
        if l2 < 1e-18 { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / l2))
        return p.distance(to: a + ab * t)
    }

    /// 耳切り法による三角形分割(反時計回りの単純多角形)。頂点番号の3つ組を返す
    static func triangulate(_ pts: [Vec2]) -> [(Int, Int, Int)] {
        let n = pts.count
        guard n >= 3 else { return [] }
        if n == 3 { return [(0, 1, 2)] }
        var idx = Array(0..<n)
        var tris: [(Int, Int, Int)] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < n * n {
            guardCount += 1
            var clipped = false
            let m = idx.count
            for k in 0..<m {
                let i0 = idx[(k + m - 1) % m], i1 = idx[k], i2 = idx[(k + 1) % m]
                let a = pts[i0], b = pts[i1], c = pts[i2]
                let convex = (b - a).cross(c - b)
                if convex <= 1e-14 { continue }
                var ear = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if pointInTriangle(pts[j], a, b, c) { ear = false; break }
                }
                if ear {
                    tris.append((i0, i1, i2))
                    idx.remove(at: k)
                    clipped = true
                    break
                }
            }
            if !clipped {
                // 退化した頂点(一直線上)を1つ取り除いて続ける
                var removed = false
                for k in 0..<m {
                    let a = pts[idx[(k + m - 1) % m]], b = pts[idx[k]], c = pts[idx[(k + 1) % m]]
                    if abs((b - a).cross(c - b)) <= 1e-12 {
                        idx.remove(at: k)
                        removed = true
                        break
                    }
                }
                if !removed {
                    // 自己交差などで分割できない: 扇形で埋める
                    for k in 1..<(idx.count - 1) { tris.append((idx[0], idx[k], idx[k + 1])) }
                    return tris
                }
            }
        }
        if idx.count == 3 { tris.append((idx[0], idx[1], idx[2])) }
        return tris
    }

    private static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let d1 = (b - a).cross(p - a)
        let d2 = (c - b).cross(p - b)
        let d3 = (a - c).cross(p - c)
        return d1 >= -1e-12 && d2 >= -1e-12 && d3 >= -1e-12
    }

    /// 多角形の内側にある1点(三角形分割の最初の三角形の重心)
    static func interiorPoint(_ pts: [Vec2]) -> Vec2 {
        let ccw = signedArea(pts) >= 0 ? pts : pts.reversed()
        if let t = triangulate(ccw).first {
            return (ccw[t.0] + ccw[t.1] + ccw[t.2]) / 3
        }
        return pts.first ?? .zero
    }

    /// 反時計回りの多角形を内側へ d だけずらす(d < 0 なら外側)。
    /// 頂点ごとに角の二等分線方向へ動かす簡易オフセット。
    static func offset(_ pts: [Vec2], by d: Double) -> [Vec2] {
        let n = pts.count
        guard n >= 3, abs(d) > 1e-12 else { return pts }
        var out: [Vec2] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let p0 = pts[(i + n - 1) % n], p1 = pts[i], p2 = pts[(i + 1) % n]
            let n1 = (p1 - p0).normalized.perp
            let n2 = (p2 - p1).normalized.perp
            var m = (n1 + n2).normalized
            if m.length < 0.5 { m = n1 }
            let c = max(0.25, m.dot(n1))
            out.append(p1 + m * (d / c))
        }
        return out
    }

    /// オフセットで形がつぶれていないか(各辺の向きが元と同じか)
    static func offsetIsValid(_ original: [Vec2], _ shifted: [Vec2]) -> Bool {
        guard original.count == shifted.count, original.count >= 3 else { return false }
        let n = original.count
        for i in 0..<n {
            let e0 = original[(i + 1) % n] - original[i]
            let e1 = shifted[(i + 1) % n] - shifted[i]
            if e0.length < 1e-9 { continue }
            if e0.dot(e1) <= 0 { return false }
        }
        return signedArea(shifted) > 0
    }
}
