import Foundation
import SwiftUI

/// アプリ全体の状態。特徴の履歴を持ち、変更のたびに形状を作り直して保存する
/// (メインスレッドからだけ使う)
final class ModelStore: ObservableObject {
    @Published var features: [Feature] = [] {
        didSet {
            save()
            rebuild()
        }
    }
    @Published var selectedID: UUID?
    @Published private(set) var mesh = TriMesh()
    @Published private(set) var meshVersion = 0
    @Published private(set) var isBuilding = false
    @Published private(set) var messages: [String] = []

    private var buildTask: Task<Void, Never>?
    private var buildToken = 0

    init() {
        load()
        if features.isEmpty { features = ModelStore.sample() }
        rebuild()
    }

    // MARK: 編集

    func feature(_ id: UUID?) -> Feature? {
        features.first { $0.id == id }
    }

    func upsert(_ f: Feature) {
        if let i = features.firstIndex(where: { $0.id == f.id }) {
            features[i] = f
        } else {
            features.append(f)
        }
        selectedID = f.id
    }

    func delete(_ id: UUID) {
        features.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = features.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < features.count else { return }
        features.swapAt(i, j)
    }

    func toggleSuppressed(_ id: UUID) {
        guard let i = features.firstIndex(where: { $0.id == id }) else { return }
        features[i].suppressed.toggle()
    }

    func newFeature(kind: FeatureKind) -> Feature {
        let count = features.filter { $0.kind == kind }.count + 1
        var f = Feature(name: "\(kind.label)\(count)", kind: kind)
        if kind == .cut {
            // 引き抜きは、いまの形の上面にスケッチして下へ掘るのを初期値にする
            f.direction = .reverse
            if !mesh.bounds.isEmpty {
                f.sketch.plane.offset = extremeAlongNormal(f.sketch.plane.kind, max: true)
            }
        }
        return f
    }

    /// いまの形を平面の法線方向に見たときの最大(最小)位置
    func extremeAlongNormal(_ kind: SketchPlaneKind, max: Bool) -> Double {
        let n = SketchPlane(kind: kind, offset: 0).normal
        guard !mesh.positions.isEmpty else { return 0 }
        var best = max ? -Double.infinity : Double.infinity
        let b = mesh.bounds
        for x in [b.min.x, b.max.x] {
            for y in [b.min.y, b.max.y] {
                for z in [b.min.z, b.max.z] {
                    let d = n.dot(Vec3(x, y, z))
                    best = max ? Swift.max(best, d) : Swift.min(best, d)
                }
            }
        }
        return (best * 1000).rounded() / 1000
    }

    // MARK: 形状の作り直し

    func rebuild() {
        let snapshot = features
        buildToken += 1
        let token = buildToken
        buildTask?.cancel()
        isBuilding = true
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = SolidBuilder.build(snapshot)
            guard let store = self else { return }
            await MainActor.run { store.apply(result, token: token) }
        }
    }

    private func apply(_ result: SolidBuilder.Result, token: Int) {
        guard token == buildToken else { return }
        mesh = result.mesh
        messages = result.messages
        meshVersion += 1
        isBuilding = false
    }

    // MARK: 保存

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("model.json")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(ModelData(features: features))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("保存に失敗: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let model = try? JSONDecoder().decode(ModelData.self, from: data) else { return }
        features = model.features
    }

    func resetToSample() {
        selectedID = nil
        features = ModelStore.sample()
    }

    func clearAll() {
        selectedID = nil
        features = []
    }

    /// 最初に表示する見本: 角Rの板 → 丸穴の引き抜き(入口R) → 上面フィレット付きのボス
    static func sample() -> [Feature] {
        var base = Feature(name: "押し出し1", kind: .extrude)
        var rect = SketchShape.rectangle(Vec2(-40, -25), Vec2(40, 25))
        rect.setAllRadii(8)
        base.sketch.shapes = [rect]
        base.distance = 12
        base.endFillet = 2

        var boss = Feature(name: "押し出し2", kind: .extrude)
        boss.sketch.plane.offset = 12
        boss.sketch.shapes = [.circle(center: Vec2(-15, 0), radius: 12)]
        boss.distance = 15
        boss.endFillet = 3

        var hole = Feature(name: "引き抜き1", kind: .cut)
        hole.sketch.plane.offset = 27
        hole.direction = .reverse
        hole.throughAll = true
        hole.startFillet = 1.5
        hole.sketch.shapes = [.circle(center: Vec2(-15, 0), radius: 5)]

        var pocket = Feature(name: "引き抜き2", kind: .cut)
        pocket.sketch.plane.offset = 12
        pocket.direction = .reverse
        pocket.distance = 6
        pocket.endFillet = 2
        var slot = SketchShape.rectangle(Vec2(8, -12), Vec2(30, 12))
        slot.setAllRadii(4)
        pocket.sketch.shapes = [slot]

        return [base, boss, hole, pocket]
    }
}

/// STL(バイナリ)書き出し
enum STLExporter {
    static func data(from mesh: TriMesh, name: String = "Model3D") -> Data {
        var d = Data()
        var header = Array(name.utf8.prefix(80))
        header += Array(repeating: 0, count: 80 - header.count)
        d.append(contentsOf: header)
        appendUInt32(&d, UInt32(mesh.triangleCount))
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[t * 3], b = mesh.positions[t * 3 + 1], c = mesh.positions[t * 3 + 2]
            let n = (b - a).cross(c - a).normalized
            for v in [n, a, b, c] {
                appendFloat(&d, Float(v.x))
                appendFloat(&d, Float(v.y))
                appendFloat(&d, Float(v.z))
            }
            d.append(contentsOf: [0, 0])
        }
        return d
    }

    static func writeTemporary(_ mesh: TriMesh) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Model3D.stl")
        try data(from: mesh).write(to: url, options: .atomic)
        return url
    }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func appendFloat(_ d: inout Data, _ v: Float) {
        appendUInt32(&d, v.bitPattern)
    }
}
