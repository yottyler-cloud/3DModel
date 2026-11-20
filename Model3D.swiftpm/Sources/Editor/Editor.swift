import SwiftUI

enum CommandTab: String, CaseIterable, Identifiable {
    case features, sketch
    var id: String { rawValue }
    var label: String { self == .features ? "フィーチャー" : "スケッチ" }
}

/// グラフィックス領域・ツリーで選んでいるもの
enum Selection: Equatable {
    case refPlane(RefPlane)
    case face(SketchPlane, triangles: [Int])
    case feature(UUID)

    /// スケッチを描ける平面
    var sketchPlane: SketchPlane? {
        switch self {
        case .refPlane(let p): return p.plane
        case .face(let p, _): return p
        case .feature: return nil
        }
    }
}

/// 平面の選択を待っているコマンド
enum PendingCommand: Equatable {
    case sketch(SketchTool)
    case feature(FeatureKind)
}

enum ViewKind: Equatable {
    case iso, front, back, left, right, top, bottom, fit
    case normal(SketchPlane)
}

struct ViewCommand: Equatable {
    var serial = 0
    var kind: ViewKind = .iso
}

/// 押し出し・カット・フィレットの PropertyManager の内容
struct FeatureSession {
    var draft: Feature
    var isNew: Bool
    /// 置きかえるフィーチャー(使うスケッチ、または編集中のもの)
    var replacing: UUID?
}

/// フィレットで選べるエッジ
struct EdgeCandidate: Equatable {
    var ref: EdgeRef
    var points: [Vec3]
    var closed: Bool
}

/// 画面の操作の流れ(どのコマンドの途中か)をまとめる
final class Editor: ObservableObject {
    let store: ModelStore

    @Published var tab: CommandTab = .features
    @Published var selection: Selection? {
        didSet { selectionChanged() }
    }
    @Published var sketch: SketchSession?
    @Published var session: FeatureSession? {
        didSet { syncPreview() }
    }
    @Published var awaiting: PendingCommand?
    @Published var viewCommand = ViewCommand()
    @Published var showEdges = true
    @Published var canvasSize: CGSize = .zero
    @Published var expanded: Set<UUID> = []
    @Published var toast: String?
    @Published var exportURL: URL?

    init(store: ModelStore) {
        self.store = store
    }

    // MARK: 案内

    var prompt: String {
        if let s = sketch {
            return "スケッチ: \(s.tool.label) — \(s.tool.hint)"
        }
        if let s = session {
            switch s.draft.kind {
            case .fillet: return "フィレットするエッジをグラフィックス領域でタップしてください"
            default: return "条件を入れて ✓ で確定します"
            }
        }
        switch awaiting {
        case .sketch?: return "スケッチを描く平面(ツリーの正面・平面・右側面)か、平らな面を選んでください"
        case .feature(let k)?: return "\(k.label): スケッチする平面か平らな面を選んでください"
        case nil: break
        }
        switch selection {
        case .refPlane(let p)?: return "「\(p.label)」を選択中。スケッチや押し出しを始められます"
        case .face?: return "面を選択中。スケッチや押し出しを始められます"
        case .feature(let id)?: return "「\(store.feature(id)?.name ?? "")」を選択中"
        case nil: return "平面か面を選んで、スケッチを始めます"
        }
    }

    func show(_ kind: ViewKind) {
        viewCommand = ViewCommand(serial: viewCommand.serial + 1, kind: kind)
    }

    func flash(_ message: String) {
        toast = message
        let m = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == m { self?.toast = nil }
        }
    }

    private func selectionChanged() {
        guard let pending = awaiting, let plane = selection?.sketchPlane else { return }
        awaiting = nil
        switch pending {
        case .sketch(let tool): startSketch(on: plane, tool: tool, continueWith: nil)
        case .feature(let k): startSketch(on: plane, tool: .cornerRect, continueWith: k)
        }
    }

    // MARK: スケッチ

    /// 「スケッチ」ボタン
    func sketchButton() {
        if sketch != nil {
            exitSketch(accept: true)
            return
        }
        guard session == nil else { return }
        if case .feature(let id)? = selection, let f = store.feature(id), f.hasSketch {
            editSketch(id)
        } else if let p = selection?.sketchPlane {
            startSketch(on: p, tool: .line, continueWith: nil)
        } else {
            awaiting = .sketch(.line)
        }
    }

    /// スケッチツールのボタン(スケッチ中でなければ、平面を選んでスケッチを始める)
    func chooseTool(_ t: SketchTool) {
        if sketch != nil {
            sketch?.finishPolygon()
            sketch?.tool = t
            return
        }
        guard session == nil else { return }
        if let p = selection?.sketchPlane {
            startSketch(on: p, tool: t, continueWith: nil)
        } else {
            awaiting = .sketch(t)
        }
    }

    func startSketch(on plane: SketchPlane, tool: SketchTool, continueWith: FeatureKind?) {
        let name = store.nextName(.sketch)
        var f = Feature(name: name, kind: .sketch)
        f.sketchName = name
        f.sketch.plane = plane
        var s = SketchSession(feature: f, isNew: true, continueWith: continueWith)
        s.tool = tool
        s.fit(size: canvasSize, points: modelOutline(on: plane))
        selection = nil
        sketch = s
        tab = .sketch
    }

    func editSketch(_ id: UUID) {
        guard sketch == nil, session == nil, let f = store.feature(id), f.hasSketch else { return }
        var s = SketchSession(feature: f, isNew: false, continueWith: nil)
        s.tool = .select
        s.fit(size: canvasSize, points: modelOutline(on: f.sketch.plane))
        selection = nil
        sketch = s
        tab = .sketch
    }

    /// スケッチ終了(accept = false なら変更を捨てる)
    func exitSketch(accept: Bool) {
        guard var s = sketch else { return }
        s.finishPolygon()
        sketch = nil
        show(.iso)
        guard accept else {
            tab = .features
            return
        }
        let valid = s.shapes.contains { $0.isValid }
        if s.isNew {
            guard valid else {
                tab = .features
                flash("閉じた図形がないので、スケッチは作られませんでした")
                return
            }
            store.insert(s.feature)
            if let k = s.continueWith {
                beginFeature(kind: k, sketchFeature: s.feature)
            } else {
                selection = .feature(s.feature.id)
                tab = .features
            }
        } else {
            store.update(s.feature)
            selection = .feature(s.feature.id)
            tab = .features
        }
    }

    /// スケッチの参照情報
    func sketchEnv() -> SketchEnv {
        guard let s = sketch else { return SketchEnv(size: canvasSize, references: [], modelPoints: []) }
        let refs = store.features
            .filter { $0.id != s.feature.id && $0.hasSketch && !$0.suppressed
                && $0.sketch.plane.isCoplanar(with: s.plane) }
            .flatMap { $0.sketch.shapes }
        return SketchEnv(size: canvasSize, references: refs, modelPoints: store.mesh.edgePoints(on: s.plane))
    }

    /// 形を平面に投影した範囲(スケッチの表示合わせ用)
    private func modelOutline(on plane: SketchPlane) -> [Vec2] {
        let b = store.mesh.bounds
        guard !b.isEmpty else { return [] }
        var pts: [Vec2] = []
        for x in [b.min.x, b.max.x] {
            for y in [b.min.y, b.max.y] {
                for z in [b.min.z, b.max.z] { pts.append(plane.project(Vec3(x, y, z))) }
            }
        }
        return pts
    }

    // スケッチ画面からの入力
    func sketchBegan(_ p: CGPoint) { let env = sketchEnv(); sketch?.began(p, env) }
    func sketchMoved(_ p: CGPoint) { let env = sketchEnv(); sketch?.moved(p, env) }
    func sketchEnded(_ p: CGPoint) { let env = sketchEnv(); sketch?.ended(p, env) }
    func sketchCancelled() { sketch?.cancelInProgress() }
    func sketchPan(_ d: CGSize) {
        sketch?.pan.width += d.width
        sketch?.pan.height += d.height
    }
    func sketchPinch(_ s: CGFloat, _ c: CGPoint) {
        let size = canvasSize
        sketch?.zoom(by: s, around: c, size: size)
    }
    func sketchFit() {
        guard let s = sketch else { return }
        let pts = modelOutline(on: s.plane)
        sketch?.fit(size: canvasSize, points: pts)
    }

    // MARK: フィーチャー

    /// 押し出し・押し出しカットのボタン
    func featureButton(_ kind: FeatureKind) {
        guard session == nil else { return }
        if var s = sketch {
            // スケッチ中なら、スケッチを終了してそのまま続ける
            if s.isNew {
                s.continueWith = kind
                sketch = s
                exitSketch(accept: true)
                return
            }
            exitSketch(accept: true)
            if let f = store.feature(s.feature.id), f.kind == .sketch {
                beginFeature(kind: kind, sketchFeature: f)
            }
            return
        }
        if kind == .cut && store.mesh.positions.isEmpty {
            flash("先に押し出しで形をつくってください")
            return
        }
        if case .feature(let id)? = selection, let f = store.feature(id), f.kind == .sketch {
            beginFeature(kind: kind, sketchFeature: f)
        } else if let f = store.features.last(where: { $0.kind == .sketch && !$0.suppressed
            && !store.isRolledBack($0.id) }) {
            beginFeature(kind: kind, sketchFeature: f)
        } else if let p = selection?.sketchPlane {
            startSketch(on: p, tool: .cornerRect, continueWith: kind)
        } else {
            awaiting = .feature(kind)
        }
    }

    /// スケッチ(ツリーにあるもの)から押し出し・カットを始める
    func beginFeature(kind: FeatureKind, sketchFeature sk: Feature) {
        var f = Feature(name: store.nextName(kind), kind: kind)
        f.sketch = sk.sketch
        f.sketchName = sk.sketchName.isEmpty ? sk.name : sk.sketchName
        // 形がある側を見て、向きを決める(押し出しは形の外へ、カットは形の中へ)
        if let r = store.mesh.range(along: sk.sketch.plane) {
            let onPositive = r.max > 1e-6
            let onNegative = r.min < -1e-6
            if kind == .cut {
                f.reversed = !(onPositive && !onNegative)
                f.distance = 5
            } else {
                f.reversed = onPositive && !onNegative
            }
        }
        selection = nil
        tab = .features
        session = FeatureSession(draft: f, isNew: true, replacing: sk.id)
    }

    func filletButton() {
        if sketch != nil {
            chooseTool(.sketchFillet)
            return
        }
        guard session == nil else { return }
        guard !store.mesh.positions.isEmpty else {
            flash("先に押し出しで形をつくってください")
            return
        }
        var f = Feature(name: store.nextName(.fillet), kind: .fillet)
        f.filletRadius = 3
        selection = nil
        tab = .features
        session = FeatureSession(draft: f, isNew: true, replacing: nil)
    }

    func editFeature(_ id: UUID) {
        guard sketch == nil, session == nil, let f = store.feature(id) else { return }
        if f.kind == .sketch {
            editSketch(id)
        } else {
            selection = nil
            tab = .features
            session = FeatureSession(draft: f, isNew: false, replacing: f.id)
        }
    }

    func confirmFeature() {
        guard let s = session else { return }
        if s.draft.kind == .fillet && s.draft.filletEdges.isEmpty {
            flash("フィレットするエッジを選んでください")
            return
        }
        if s.isNew {
            store.insert(s.draft, replacing: s.replacing)
        } else {
            store.update(s.draft)
        }
        session = nil
        selection = .feature(s.draft.id)
    }

    func cancelFeature() {
        session = nil
    }

    func cancelAll() {
        awaiting = nil
        if sketch != nil { exitSketch(accept: false) }
        if session != nil { cancelFeature() }
    }

    private func syncPreview() {
        let spec = session.map { ModelStore.PreviewSpec(feature: $0.draft, replacing: $0.replacing) }
        if store.preview != spec { store.preview = spec }
    }

    /// PropertyManager 用の Binding
    func draft<T>(_ kp: WritableKeyPath<Feature, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { [weak self] in self?.session?.draft[keyPath: kp] ?? fallback },
                set: { [weak self] v in self?.session?.draft[keyPath: kp] = v })
    }

    // MARK: グラフィックス領域のタップ

    func tapped(face: SceneHit?, edge: EdgeRef?) {
        if sketch != nil { return }
        if let s = session {
            if s.draft.kind == .fillet {
                guard let e = edge else { return }
                if let i = s.draft.filletEdges.firstIndex(of: e) {
                    session?.draft.filletEdges.remove(at: i)
                } else {
                    session?.draft.filletEdges.append(e)
                }
            }
            return
        }
        guard let hit = face else {
            selection = nil
            return
        }
        if store.mesh.isPlanar(hit.triangle) {
            let n = store.mesh.faceNormals[hit.triangle]
            let plane = SketchPlane.from(normal: n, through: hit.point, name: "面")
            selection = .face(plane, triangles: store.mesh.coplanarTriangles(with: hit.triangle))
        } else {
            selection = nil
            flash("曲面にはスケッチできません。平らな面を選んでください")
        }
    }

    // MARK: フィレットのエッジ

    /// フィレットで選べるエッジ(対象は押し出し・カット)
    func edgeCandidates() -> [EdgeCandidate] {
        guard let s = session, s.draft.kind == .fillet else { return [] }
        var fs = store.featuresForBuild().filter { $0.id != s.draft.id }
        if let i = store.index(of: s.draft.id) {
            // 既存フィレットの編集: それより前のフィーチャーだけ
            let before = Set(store.features.prefix(i).map(\.id))
            fs = fs.filter { before.contains($0.id) }
        }
        return Editor.candidates(for: SolidBuilder.effective(fs), mesh: store.mesh)
    }

    /// あるフィレットで選んだエッジの形(表示用)
    func edges(of refs: [EdgeRef], excluding filletID: UUID?) -> [EdgeCandidate] {
        let fs = store.featuresForBuild().filter { $0.id != filletID }
        let all = Editor.candidates(for: SolidBuilder.effective(fs), mesh: store.mesh)
        return all.filter { refs.contains($0.ref) }
    }

    static func candidates(for features: [Feature], mesh: TriMesh) -> [EdgeCandidate] {
        var out: [EdgeCandidate] = []
        for f in features {
            let shapes = f.sketch.shapes.filter { $0.isValid }
            if shapes.isEmpty { continue }
            let plane = f.sketch.plane
            var (h0, h1, atBottom) = SolidBuilder.extent(of: f)
            let isMid = f.endCondition == .midPlane
            let through = f.kind == .cut && f.endCondition == .throughAll
            if through, let r = mesh.range(along: plane) {
                h0 = max(h0, r.min)
                h1 = min(h1, r.max)
                if h1 <= h0 { continue }
            }
            let hStart = atBottom ? h0 : h1
            let hEnd = atBottom ? h1 : h0
            for shape in shapes {
                let outline = Polygon2D.dedupe(ProfileGeometry.outline(shape))
                func loop(_ h: Double) -> [Vec3] { outline.map { plane.point($0, height: h) } }
                if isMid {
                    out.append(EdgeCandidate(ref: .end(f.id), points: loop(h0), closed: true))
                    out.append(EdgeCandidate(ref: .end(f.id), points: loop(h1), closed: true))
                } else {
                    out.append(EdgeCandidate(ref: .start(f.id), points: loop(hStart), closed: true))
                    if !through {
                        out.append(EdgeCandidate(ref: .end(f.id), points: loop(hEnd), closed: true))
                    }
                }
                for (i, c) in shape.corners.enumerated() {
                    out.append(EdgeCandidate(ref: .corner(f.id, shape.id, i),
                                             points: [plane.point(c, height: h0), plane.point(c, height: h1)],
                                             closed: false))
                }
            }
        }
        return out
    }

    func describe(_ e: EdgeRef) -> String {
        let name = store.feature(e.featureID)?.name ?? "(削除済み)"
        let kind = store.feature(e.featureID)?.kind
        switch e {
        case .start:
            let merged = store.feature(e.featureID)?.mergeResult ?? true
            return "\(name): " + (kind == .cut ? "入口のふち" : (merged ? "付け根(スケッチ面側)" : "スケッチ面側のふち"))
        case .end: return "\(name): " + (kind == .cut ? "底のすみ" : "先端側のふち")
        case .corner(_, _, let k): return "\(name): 角\(k + 1)のエッジ"
        }
    }

    // MARK: 書き出し

    func refreshExport() {
        exportURL = try? STLExporter.writeTemporary(store.mesh, name: store.partName)
    }
}

/// グラフィックス領域で当たった面
struct SceneHit {
    var point: Vec3
    var triangle: Int
}
