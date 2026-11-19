import Foundation

/// 描画・書き出し用の三角形メッシュ(3頂点ずつ)と、折れ目のエッジ
struct TriMesh {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    /// 三角形ごとの面の法線と、平面の位置(n·p)
    var faceNormals: [Vec3] = []
    var facePlaneW: [Double] = []
    /// 折れ目(稜線)の線分。2点ずつ。少しだけ外へずらしてある
    var edges: [Vec3] = []
    /// ずらす前の稜線(スナップ用)
    var rawEdges: [Vec3] = []
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
        var faceW: [Vec3] = []   // 長さ = 面積×2(重み)
        var keep: [(Vec3, Vec3, Vec3)] = []
        for t in tris {
            let c = (t.1 - t.0).cross(t.2 - t.0)
            if c.length < 1e-10 { continue }
            keep.append(t)
            faceW.append(c)
        }
        let fn = faceW.map { $0.normalized }

        // 同じ位置の頂点を集める
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

        // なめらかな面は法線を平均する(角度40°以上は折れ目)
        let crease = cos(40.0 * Double.pi / 180)
        positions.reserveCapacity(keep.count * 3)
        normals.reserveCapacity(keep.count * 3)
        for (i, t) in keep.enumerated() {
            for v in [t.0, t.1, t.2] {
                var sum = Vec3.zero
                for j in groups[key(v)] ?? [] where fn[j].dot(fn[i]) >= crease {
                    sum = sum + faceW[j]
                }
                positions.append(v)
                normals.append(sum.length > 0 ? sum.normalized : fn[i])
                bounds.add(v)
            }
            faceNormals.append(fn[i])
            facePlaneW.append(fn[i].dot(t.0))
        }

        // 稜線: 同じ直線上にある辺どうしを比べ、となりの面と角度が大きく違う区間だけを取り出す
        // (CSG で生じる T 字の継ぎ目では、辺の一部だけが稜線になることがある)
        struct LineEdge { var tri: Int; var a: Vec3; var b: Vec3 }
        func lineKey(_ a: Vec3, _ b: Vec3) -> [Int64] {
            var d = (b - a).normalized
            for c in [d.x, d.y, d.z] where abs(c) > 1e-6 {
                if c < 0 { d = -d }
                break
            }
            let p = a - d * a.dot(d)
            return [d.x, d.y, d.z].map { Int64(($0 * 1e4).rounded()) }
                + [p.x, p.y, p.z].map { Int64(($0 * 1e3).rounded()) }
        }
        var lines: [[Int64]: [LineEdge]] = [:]
        for (i, t) in keep.enumerated() {
            let c = [t.0, t.1, t.2]
            for e in 0..<3 {
                let a = c[e], b = c[(e + 1) % 3]
                if (b - a).length < 1e-7 { continue }
                lines[lineKey(a, b), default: []].append(LineEdge(tri: i, a: a, b: b))
            }
        }
        let lift = max(bounds.size.length * 0.0008, 0.005)
        for (_, list) in lines {
            for e in list {
                let ab = e.b - e.a
                let l2 = ab.dot(ab)
                let len = l2.squareRoot()
                var creaseIv: [(Double, Double)] = []
                var smoothIv: [(Double, Double)] = []
                var other = fn[e.tri]
                for o in list where o.tri != e.tri {
                    let tc = (o.a - e.a).dot(ab) / l2, td = (o.b - e.a).dot(ab) / l2
                    let lo = max(0, min(tc, td)), hi = min(1, max(tc, td))
                    if (hi - lo) * len <= 1e-5 { continue }
                    if fn[o.tri].dot(fn[e.tri]) >= crease {
                        smoothIv.append((lo, hi))
                    } else {
                        creaseIv.append((lo, hi))
                        other = fn[o.tri]
                    }
                }
                if creaseIv.isEmpty { continue }
                let off = (fn[e.tri] + other).normalized * lift
                for (lo, hi) in TriMesh.subtract(TriMesh.merge(creaseIv), TriMesh.merge(smoothIv))
                where (hi - lo) * len > 1e-5 {
                    let p = e.a + ab * lo, q = e.a + ab * hi
                    edges.append(p + off)
                    edges.append(q + off)
                    rawEdges.append(p)
                    rawEdges.append(q)
                }
            }
        }
    }

    /// 区間の和
    static func merge(_ iv: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for v in iv.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, v.0 <= last.1 + 1e-9 {
                out[out.count - 1].1 = max(last.1, v.1)
            } else {
                out.append(v)
            }
        }
        return out
    }

    /// 区間 a から区間 b を除いた残り
    static func subtract(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for v in a {
            var cur = [v]
            for w in b {
                var next: [(Double, Double)] = []
                for c in cur {
                    if w.1 <= c.0 || w.0 >= c.1 { next.append(c); continue }
                    if w.0 > c.0 { next.append((c.0, w.0)) }
                    if w.1 < c.1 { next.append((w.1, c.1)) }
                }
                cur = next
            }
            result += cur
        }
        return result
    }

    /// 三角形 i と同じ平面にある三角形(面の選択表示用)
    func coplanarTriangles(with i: Int) -> [Int] {
        guard i >= 0, i < faceNormals.count else { return [] }
        let n = faceNormals[i], w = facePlaneW[i]
        return faceNormals.indices.filter {
            faceNormals[$0].dot(n) > 0.99999 && abs(facePlaneW[$0] - w) < 1e-4
        }
    }

    /// 三角形 i が平らな面の一部か(なめらかな曲面の一部ではないか)
    func isPlanar(_ i: Int) -> Bool {
        guard i >= 0, i < faceNormals.count else { return false }
        let n = faceNormals[i]
        return (0..<3).allSatisfy { normals[i * 3 + $0].dot(n) > 0.9999 }
    }

    /// 平面の上にある稜線の端点(スケッチのスナップ用)
    func edgePoints(on plane: SketchPlane) -> [Vec2] {
        var out: [Vec2] = []
        var seen = Set<SIMD2<Int64>>()
        let tol = 1e-4
        for p in rawEdges where abs(plane.distance(p)) < tol {
            let q = plane.project(p)
            let k = SIMD2(Int64((q.x * 100).rounded()), Int64((q.y * 100).rounded()))
            if seen.insert(k).inserted { out.append(Vec2((q.x * 1000).rounded() / 1000, (q.y * 1000).rounded() / 1000)) }
        }
        return out
    }

    /// 平面の法線方向に見た、形の範囲
    func range(along plane: SketchPlane) -> (min: Double, max: Double)? {
        guard !positions.isEmpty else { return nil }
        var lo = Double.infinity, hi = -Double.infinity
        for p in positions {
            let d = plane.distance(p)
            lo = min(lo, d)
            hi = max(hi, d)
        }
        return (lo, hi)
    }
}
