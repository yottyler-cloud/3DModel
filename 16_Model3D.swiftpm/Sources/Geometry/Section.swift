import Foundation

/// 断面表示の設定(表示だけで、モデルは変えない)
struct SectionView: Equatable {
    /// 0: 正面, 1: 平面, 2: 右側面, 3: 選択した面
    var kind: Int
    var plane: SketchPlane
    /// 平面からの位置(法線方向, mm)
    var offset: Double
    /// 反対側を表示する
    var flip: Bool
}

enum SectionBuilder {
    struct Result {
        var mesh: TriMesh
        /// 切り口の三角形(3点ずつ)
        var caps: [Vec3]
    }

    /// ソリッドを平面で切って、片側だけを残す
    static func build(_ solid: Solid, _ s: SectionView) -> Result {
        let b = solid.bounds
        guard !b.isEmpty else { return Result(mesh: TriMesh(), caps: []) }
        let big = b.size.length + 10
        let c = s.plane.project(b.center)
        let rect = SketchShape.rectangle(c - Vec2(big, big), c + Vec2(big, big))
        // 法線の向き側を取り除く(反対側なら、法線と逆の側を取り除く)
        let (h0, h1) = s.flip ? (s.offset, s.offset + 2 * big) : (s.offset - 2 * big, s.offset)
        let keep = Solid(polygons: SolidBuilder.prism(shape: rect, plane: s.plane, h0: h0, h1: h1, bottom: [], top: []))
        let cut = solid.intersect(keep)
        let mesh = TriMesh(solid: cut)
        // 切り口: 断面の平面上にある三角形
        var caps: [Vec3] = []
        let n = s.plane.normal
        let lift = n * ((s.flip ? -1 : 1) * max(b.size.length * 0.0005, 0.005))
        for t in 0..<mesh.triangleCount where abs(abs(mesh.faceNormals[t].dot(n)) - 1) < 1e-6 {
            let a = mesh.positions[t * 3], bb = mesh.positions[t * 3 + 1], cc = mesh.positions[t * 3 + 2]
            if [a, bb, cc].allSatisfy({ abs(s.plane.distance($0) - s.offset) < 1e-4 }) {
                caps += [a + lift, bb + lift, cc + lift]
            }
        }
        return Result(mesh: mesh, caps: caps)
    }
}
