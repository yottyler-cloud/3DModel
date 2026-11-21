import Foundation

/// 断面表示の設定(表示だけで、モデルは変えない)
struct SectionView: Codable, Equatable {
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
        let b: Box3 = solid.bounds
        guard !b.isEmpty else { return Result(mesh: TriMesh(), caps: []) }
        let big: Double = b.size.length + 10
        let c = s.plane.project(b.center)
        let rect = SketchShape.rectangle(c - Vec2(big, big), c + Vec2(big, big))
        // 法線の向き側を取り除く(反対側なら、法線と逆の側を取り除く)
        // (iPad の Swift Playgrounds でも型が決まるよう、型を書いておく)
        let span: Double = 2 * big
        let h0: Double = s.flip ? s.offset : s.offset - span
        let h1: Double = s.flip ? s.offset + span : s.offset
        let keep = Solid(polygons: SolidBuilder.prism(shape: rect, plane: s.plane, h0: h0, h1: h1, bottom: [], top: []))
        let cut: Solid = solid.intersect(keep)
        let mesh = TriMesh(solid: cut)
        // 切り口: 断面の平面上にある三角形
        var caps: [Vec3] = []
        let n: Vec3 = s.plane.normal
        let sign: Double = s.flip ? -1.0 : 1.0
        let liftSize: Double = Swift.max(b.size.length * 0.0005, 0.005)
        let lift: Vec3 = n * (sign * liftSize)
        for t in 0..<mesh.triangleCount {
            let fn: Vec3 = mesh.faceNormals[t]
            let parallel: Double = Swift.abs(fn.dot(n))
            if Swift.abs(parallel - 1) >= 1e-6 { continue }
            let a: Vec3 = mesh.positions[t * 3]
            let bb: Vec3 = mesh.positions[t * 3 + 1]
            let cc: Vec3 = mesh.positions[t * 3 + 2]
            let da: Double = s.plane.distance(a) - s.offset
            let db: Double = s.plane.distance(bb) - s.offset
            let dc: Double = s.plane.distance(cc) - s.offset
            if Swift.abs(da) < 1e-4 && Swift.abs(db) < 1e-4 && Swift.abs(dc) < 1e-4 {
                caps.append(a + lift)
                caps.append(bb + lift)
                caps.append(cc + lift)
            }
        }
        return Result(mesh: mesh, caps: caps)
    }
}
