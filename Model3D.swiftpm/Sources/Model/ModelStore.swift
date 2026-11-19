import Foundation
import SwiftUI

/// 部品のデータ(フィーチャーの履歴)と、計算した形。メインスレッドからだけ使う
final class ModelStore: ObservableObject {
    @Published private(set) var features: [Feature] = []
    @Published private(set) var partName = "部品1"
    /// この番号より後のフィーチャーは計算しない(nil なら最後まで)
    @Published private(set) var rollbackIndex: Int?
    /// 作成中・編集中のフィーチャー(PropertyManager で確定する前のプレビュー)
    @Published var preview: PreviewSpec? {
        didSet { if preview != oldValue { rebuild() } }
    }

    @Published private(set) var mesh = TriMesh()
    @Published private(set) var meshVersion = 0
    @Published private(set) var isBuilding = false
    @Published private(set) var messages: [String] = []

    struct PreviewSpec: Equatable {
        var feature: Feature
        /// 置きかえるフィーチャー(編集中のもの、または使うスケッチ)
        var replacing: UUID?
    }

    private var undoStack: [ModelData] = []
    private var redoStack: [ModelData] = []
    private var buildTask: Task<Void, Never>?
    private var buildToken = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init() {
        if let data = load() {
            apply(data)
        } else {
            apply(ModelData(features: ModelStore.sample()))
        }
        rebuild()
    }

    private var snapshot: ModelData {
        ModelData(partName: partName, features: features, rollbackIndex: rollbackIndex)
    }

    private func apply(_ d: ModelData) {
        partName = d.partName
        features = d.features
        rollbackIndex = d.rollbackIndex.flatMap { $0 < d.features.count ? $0 : nil }
    }

    /// 変更をまとめて行い、元に戻せるようにする
    private func change(_ body: (inout ModelData) -> Void) {
        var d = snapshot
        body(&d)
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        apply(d)
        save()
        rebuild()
    }

    func undo() {
        guard let d = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        apply(d)
        save()
        rebuild()
    }

    func redo() {
        guard let d = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        apply(d)
        save()
        rebuild()
    }

    // MARK: 編集

    func feature(_ id: UUID?) -> Feature? {
        guard let id else { return nil }
        return features.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        features.firstIndex { $0.id == id }
    }

    func isRolledBack(_ id: UUID) -> Bool {
        guard let r = rollbackIndex, let i = index(of: id) else { return false }
        return i >= r
    }

    /// 追加する。replacing があればその位置に置きかえる(スケッチを押し出しにするとき)
    func insert(_ f: Feature, replacing: UUID? = nil) {
        change { d in
            if let id = replacing, let i = d.features.firstIndex(where: { $0.id == id }) {
                d.features[i] = f
            } else if let r = d.rollbackIndex {
                d.features.insert(f, at: r)
                d.rollbackIndex = r + 1
            } else {
                d.features.append(f)
            }
        }
    }

    func update(_ f: Feature) {
        change { d in
            if let i = d.features.firstIndex(where: { $0.id == f.id }) { d.features[i] = f }
        }
    }

    func delete(_ id: UUID) {
        change { d in
            guard let i = d.features.firstIndex(where: { $0.id == id }) else { return }
            d.features.remove(at: i)
            // このフィーチャーのエッジを使っていたフィレットから外す
            for k in d.features.indices where d.features[k].kind == .fillet {
                d.features[k].filletEdges.removeAll { $0.featureID == id }
            }
            if let r = d.rollbackIndex, i < r { d.rollbackIndex = r - 1 }
            if let r = d.rollbackIndex, r >= d.features.count { d.rollbackIndex = nil }
        }
    }

    func toggleSuppressed(_ id: UUID) {
        change { d in
            if let i = d.features.firstIndex(where: { $0.id == id }) { d.features[i].suppressed.toggle() }
        }
    }

    func rename(_ id: UUID, to name: String) {
        change { d in
            if let i = d.features.firstIndex(where: { $0.id == id }) { d.features[i].name = name }
        }
    }

    /// このフィーチャーの直前までロールバック(nil で最後へ)
    func rollback(before id: UUID?) {
        change { d in
            d.rollbackIndex = id.flatMap { id in d.features.firstIndex { $0.id == id } }
        }
    }

    func resetToSample() {
        change { d in d = ModelData(features: ModelStore.sample()) }
    }

    func newPart() {
        change { d in d = ModelData() }
    }

    /// 新しい名前(押し出し3 など)
    func nextName(_ kind: FeatureKind) -> String {
        var n = 1
        let names = Set(features.map(\.name) + features.map(\.sketchName))
        while names.contains("\(kind.label)\(n)") { n += 1 }
        return "\(kind.label)\(n)"
    }

    // MARK: 形の作り直し

    /// 計算に使うフィーチャー(プレビューを入れ、ロールバック位置まで)
    func featuresForBuild() -> [Feature] {
        var fs = features
        var limit = rollbackIndex ?? fs.count
        if let p = preview {
            if let id = p.replacing, let i = fs.firstIndex(where: { $0.id == id }) {
                fs[i] = p.feature
            } else {
                fs.insert(p.feature, at: min(limit, fs.count))
                limit += 1
            }
        }
        return Array(fs.prefix(limit))
    }

    func rebuild() {
        let snapshot = featuresForBuild()
        buildToken += 1
        let token = buildToken
        buildTask?.cancel()
        isBuilding = true
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = SolidBuilder.build(snapshot)
            guard let store = self else { return }
            await MainActor.run { store.finishBuild(result, token: token) }
        }
    }

    private func finishBuild(_ result: SolidBuilder.Result, token: Int) {
        guard token == buildToken else { return }
        mesh = result.mesh
        messages = result.messages
        meshVersion += 1
        isBuilding = false
    }

    // MARK: 保存

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("part.json")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("保存に失敗: \(error)")
        }
    }

    private func load() -> ModelData? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ModelData.self, from: data)
    }

    // MARK: 見本

    /// 角Rの板 → ボス → 貫通穴 → ポケット → フィレット
    static func sample() -> [Feature] {
        let top = RefPlane.top.plane

        var s1 = SketchShape.rectangle(Vec2(-40, -25), Vec2(40, 25))
        s1.setAllRadii(8)
        var base = Feature(name: "押し出し1", kind: .extrude)
        base.sketchName = "スケッチ1"
        base.sketch = Sketch(plane: top, shapes: [s1])
        base.distance = 12

        let face12 = SketchPlane.from(normal: Vec3(0, 1, 0), through: Vec3(0, 12, 0), name: "面")
        var boss = Feature(name: "押し出し2", kind: .extrude)
        boss.sketchName = "スケッチ2"
        boss.sketch = Sketch(plane: face12, shapes: [.circle(center: Vec2(-15, 0), radius: 12)])
        boss.distance = 15

        let face27 = SketchPlane.from(normal: Vec3(0, 1, 0), through: Vec3(0, 27, 0), name: "面")
        var hole = Feature(name: "押し出しカット1", kind: .cut)
        hole.sketchName = "スケッチ3"
        hole.sketch = Sketch(plane: face27, shapes: [.circle(center: Vec2(-15, 0), radius: 5)])
        hole.endCondition = .throughAll
        hole.reversed = true

        var slot = SketchShape.rectangle(Vec2(8, -12), Vec2(30, 12))
        slot.setAllRadii(4)
        var pocket = Feature(name: "押し出しカット2", kind: .cut)
        pocket.sketchName = "スケッチ4"
        pocket.sketch = Sketch(plane: face12, shapes: [slot])
        pocket.distance = 6
        pocket.reversed = true

        var fillet = Feature(name: "フィレット1", kind: .fillet)
        fillet.filletRadius = 2
        fillet.filletEdges = [.end(base.id), .end(boss.id), .start(hole.id), .end(pocket.id)]

        return [base, boss, hole, pocket, fillet]
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

    static func writeTemporary(_ mesh: TriMesh, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).stl")
        try data(from: mesh, name: name).write(to: url, options: .atomic)
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
