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
    /// 面に隠れていても選べる(スケッチの線)
    var alwaysVisible = false

    /// 角から伸びる縦のエッジか
    var isCornerEdge: Bool {
        if case .corner = ref { return true }
        return false
    }
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
    @Published var dataURL: URL?

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
            case .fillet, .chamfer: return "\(s.draft.kind.label)するエッジをグラフィックス領域でタップしてください"
            case .shell:
                return "厚みを入れ、開口にする面をタップします(選ばなければ中が閉じた空洞)"
            case .revolve, .revolveCut:
                return s.draft.revolveAxis == nil
                    ? "回転軸にするスケッチの線をタップしてください"
                    : "軸: \(describeAxis(s.draft))。ほかの線をタップすると軸を変えられます"
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
        case .feature(let k): startSketch(on: plane, tool: k.isRevolve ? .line : .cornerRect, continueWith: k)
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
        let valid = s.shapes.contains { $0.isProfile }
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
        if kind.isSubtractive && store.mesh.positions.isEmpty {
            flash("先に押し出しか回転で形をつくってください")
            return
        }
        if case .feature(let id)? = selection, let f = store.feature(id), f.kind == .sketch {
            beginFeature(kind: kind, sketchFeature: f)
        } else if let f = store.features.last(where: { $0.kind == .sketch && !$0.suppressed
            && !store.isRolledBack($0.id) }) {
            beginFeature(kind: kind, sketchFeature: f)
        } else if let p = selection?.sketchPlane {
            startSketch(on: p, tool: kind.isRevolve ? .line : .cornerRect, continueWith: kind)
        } else {
            awaiting = .feature(kind)
        }
    }

    /// スケッチ(ツリーにあるもの)から押し出し・カットを始める
    func beginFeature(kind: FeatureKind, sketchFeature sk: Feature) {
        var f = Feature(name: store.nextName(kind), kind: kind)
        f.sketch = sk.sketch
        f.sketchName = sk.sketchName.isEmpty ? sk.name : sk.sketchName
        if kind.isRevolve {
            // 回転: 360°が初期値(distance を角度として使う)
            f.distance = 360
            // 中心線があれば、それを軸にしておく(なければ、あとでスケッチの線をタップして選ぶ)
            if let c = sk.sketch.shapes.first(where: { $0.kind == .centerline && $0.isValid }) {
                f.axisShapeID = c.id
                f.axisSide = 0
            }
        } else if let r = store.mesh.range(along: sk.sketch.plane) {
            // 形がある側を見て、向きを決める(押し出しは形の外へ、カットは形の中へ)
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

    /// フィレット・面取りのボタン
    func edgeFeatureButton(_ kind: FeatureKind) {
        if sketch != nil {
            chooseTool(kind == .chamfer ? .sketchChamfer : .sketchFillet)
            return
        }
        guard session == nil else { return }
        guard !store.mesh.positions.isEmpty else {
            flash("先に押し出しで形をつくってください")
            return
        }
        var f = Feature(name: store.nextName(kind), kind: kind)
        f.filletRadius = kind == .chamfer ? 1 : 3
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

    /// シェルのボタン
    func shellButton() {
        guard sketch == nil, session == nil else { return }
        guard !store.mesh.positions.isEmpty else {
            flash("先に押し出しか回転で形をつくってください")
            return
        }
        var f = Feature(name: store.nextName(.shell), kind: .shell)
        f.filletRadius = 2
        selection = nil
        tab = .features
        session = FeatureSession(draft: f, isNew: true, replacing: nil)
    }

    /// タップした平らな面が、どの押し出しのどちらの端の面か(シェルの開口に使う)
    func capRef(for hit: SceneHit) -> EdgeRef? {
        guard hit.triangle < store.mesh.faceNormals.count else { return nil }
        let n = store.mesh.faceNormals[hit.triangle]
        var fs = store.featuresForBuild()
        if let s = session, let i = store.index(of: s.draft.id) {
            let before = Set(store.features.prefix(i).map(\.id))
            fs = fs.filter { before.contains($0.id) }
        }
        for f in SolidBuilder.effective(fs).reversed() where f.kind == .extrude {
            let plane = f.sketch.plane
            let (h0, h1, atBottom) = SolidBuilder.extent(of: f)
            let h = plane.distance(hit.point)
            let p2 = plane.project(hit.point)
            let tol = 1e-3
            if abs(n.dot(plane.normal)) > 0.999 {
                // 上下の面
                let inside = f.sketch.shapes.contains { $0.isProfile && Polygon2D.contains(ProfileGeometry.outline($0), p2) }
                guard inside else { continue }
                let isMid = f.endCondition == .midPlane
                if abs(h - h1) < tol { return isMid || atBottom ? .end(f.id) : .start(f.id) }
                if abs(h - h0) < tol { return isMid || !atBottom ? .end(f.id) : .start(f.id) }
                continue
            }
            // 側面: 図形の辺から立ち上がる面
            guard h > h0 - tol, h < h1 + tol else { continue }
            for shape in f.sketch.shapes where shape.isProfile && shape.kind != .circle {
                let c = shape.corners
                let ccw = Polygon2D.signedArea(c) > 0
                for k in c.indices {
                    let a = c[k], b = c[(k + 1) % c.count]
                    let e = (b - a).normalized
                    let out2 = ccw ? Vec2(e.y, -e.x) : Vec2(-e.y, e.x)
                    let out3 = plane.u * out2.x + plane.v * out2.y
                    guard n.dot(out3) > 0.999, Polygon2D.distanceToSegment(p2, a, b) < 1e-3 else { continue }
                    return .side(f.id, shape.id, k, false)
                }
            }
        }
        return nil
    }

    /// シェルの開口面(表示用): その端の輪郭
    func capOutlines(_ refs: [EdgeRef]) -> [EdgeCandidate] {
        var out: [EdgeCandidate] = []
        for r in refs {
            guard let f = SolidBuilder.effective(store.featuresForBuild()).first(where: { $0.id == r.featureID }) else { continue }
            let (h0, h1, atBottom) = SolidBuilder.extent(of: f)
            if case .side(_, let sid, let k, _) = r {
                // 開口にした側面: その面の四角
                guard let shape = f.sketch.shapes.first(where: { $0.id == sid }), let seg = shape.segment(k) else { continue }
                let pl = f.sketch.plane
                out.append(EdgeCandidate(ref: r, points: [pl.point(seg.0, height: h0), pl.point(seg.1, height: h0),
                                                          pl.point(seg.1, height: h1), pl.point(seg.0, height: h1)],
                                         closed: true, alwaysVisible: true))
                continue
            }
            let h: Double
            switch r {
            case .start: h = atBottom ? h0 : h1
            default: h = atBottom ? h1 : h0
            }
            for shape in f.sketch.shapes where shape.isProfile {
                let loop = Polygon2D.dedupe(ProfileGeometry.outline(shape)).map { f.sketch.plane.point($0, height: h) }
                out.append(EdgeCandidate(ref: r, points: loop, closed: true, alwaysVisible: true))
            }
        }
        return out
    }

    func confirmFeature() {
        guard let s = session else { return }
        if s.draft.kind.isEdgeFeature && s.draft.filletEdges.isEmpty {
            flash("\(s.draft.kind.label)するエッジを選んでください")
            return
        }
        if s.draft.kind == .shell && s.draft.filletRadius <= 0 {
            flash("シェルの厚みを入れてください")
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
            if s.draft.kind == .shell {
                // 開口にする面: タップした平らな面
                guard let hit = face else { return }
                guard let r = capRef(for: hit) else {
                    flash("押し出しでできた平らな面(上下・側面)を選んでください")
                    return
                }
                if let i = s.draft.filletEdges.firstIndex(of: r) {
                    session?.draft.filletEdges.remove(at: i)
                } else {
                    session?.draft.filletEdges.append(r)
                }
                return
            }
            if s.draft.kind.isRevolve {
                // 回転軸: タップしたスケッチの線
                if case .side(_, let shapeID, let k, _)? = edge {
                    session?.draft.axisShapeID = shapeID
                    session?.draft.axisSide = k
                }
                return
            }
            if s.draft.kind.isEdgeFeature {
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
            // タップ位置(画面の精度)ではなく、形の面そのものの位置を使う(ごくわずかなすき間を作らない)
            let w = store.mesh.facePlaneW[hit.triangle]
            let plane = SketchPlane.from(normal: n, through: n * w, name: "面")
            selection = .face(plane, triangles: store.mesh.coplanarTriangles(with: hit.triangle))
        } else {
            selection = nil
            flash("曲面にはスケッチできません。平らな面を選んでください")
        }
    }

    // MARK: フィレットのエッジ

    /// フィレットで選べるエッジ(対象は押し出し・カット)
    func edgeCandidates() -> [EdgeCandidate] {
        guard let s = session else { return [] }
        if s.draft.kind.isRevolve { return axisCandidates(s.draft) }
        guard s.draft.kind.isEdgeFeature else { return [] }
        var fs = store.featuresForBuild().filter { $0.id != s.draft.id }
        if let i = store.index(of: s.draft.id) {
            // 既存フィレットの編集: それより前のフィーチャーだけ
            let before = Set(store.features.prefix(i).map(\.id))
            fs = fs.filter { before.contains($0.id) }
        }
        return Editor.candidates(for: SolidBuilder.effective(fs), mesh: store.mesh)
    }

    /// 回転軸に選べるスケッチの直線(長方形・多角形の辺と中心線)
    func axisCandidates(_ f: Feature) -> [EdgeCandidate] {
        let plane = f.sketch.plane
        var out: [EdgeCandidate] = []
        for shape in f.sketch.shapes where shape.isValid {
            for k in 0..<shape.segmentCount {
                guard let seg = shape.segment(k) else { continue }
                out.append(EdgeCandidate(ref: .side(f.id, shape.id, k, false),
                                         points: [plane.point(seg.0), plane.point(seg.1)],
                                         closed: false, alwaysVisible: true))
            }
        }
        return out
    }

    /// 選んでいる回転軸(表示用)
    func axisEdge(_ f: Feature) -> EdgeCandidate? {
        guard let axis = f.revolveAxis else { return nil }
        let (a, b) = axis
        // 軸の線を少し延ばして見やすくする
        let d = (b - a).normalized * max(a.distance(to: b) * 0.15, 3)
        return EdgeCandidate(ref: .side(f.id, f.axisShapeID ?? f.id, f.axisSide ?? 0, false),
                             points: [f.sketch.plane.point(a - d), f.sketch.plane.point(b + d)],
                             closed: false, alwaysVisible: true)
    }

    /// 回転軸の説明
    func describeAxis(_ f: Feature) -> String {
        guard f.revolveAxis != nil else { return "未選択" }
        if let id = f.axisShapeID, let shape = f.sketch.shapes.first(where: { $0.id == id }) {
            return shape.kind == .centerline ? "中心線" : "\(shape.kind.label)の辺\((f.axisSide ?? 0) + 1)"
        }
        return "中心線"
    }

    /// あるフィレットで選んだエッジの形(表示用)
    func edges(of refs: [EdgeRef], excluding filletID: UUID?) -> [EdgeCandidate] {
        let fs = store.featuresForBuild().filter { $0.id != filletID }
        let all = Editor.candidates(for: SolidBuilder.effective(fs), mesh: store.mesh)
        return all.filter { refs.contains($0.ref) }
    }

    static func candidates(for features: [Feature], mesh: TriMesh) -> [EdgeCandidate] {
        var out: [EdgeCandidate] = []
        for f in features where f.kind == .extrude || f.kind == .cut {
            let shapes = f.sketch.shapes.filter { $0.isProfile }
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
                // 端のふちは辺ごとに選ぶ(円は1周で1辺)
                func addSides(_ h: Double, atEnd: Bool) {
                    if shape.kind == .circle {
                        let loop = Polygon2D.dedupe(ProfileGeometry.outline(shape)).map { plane.point($0, height: h) }
                        out.append(EdgeCandidate(ref: .side(f.id, shape.id, 0, atEnd), points: loop, closed: true))
                        return
                    }
                    let c = shape.corners
                    for k in c.indices {
                        out.append(EdgeCandidate(ref: .side(f.id, shape.id, k, atEnd),
                                                 points: [plane.point(c[k], height: h),
                                                          plane.point(c[(k + 1) % c.count], height: h)],
                                                 closed: false))
                    }
                }
                if isMid {
                    addSides(h0, atEnd: true)
                    addSides(h1, atEnd: true)
                } else {
                    addSides(hStart, atEnd: false)
                    if !through { addSides(hEnd, atEnd: true) }
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
        case .corner(_, _, let k): return "\(name): 角\(k + 1)の縦のエッジ"
        case .side(_, _, let k, let atEnd):
            let whereText: String
            if kind == .cut {
                whereText = atEnd ? "底" : "入口"
            } else {
                let merged = store.feature(e.featureID)?.mergeResult ?? true
                whereText = atEnd ? "先端側" : (merged ? "付け根" : "スケッチ面側")
            }
            return "\(name): \(whereText)の辺\(k + 1)"
        }
    }

    // MARK: 書き出し

    func refreshExport() {
        exportURL = try? STLExporter.writeTemporary(store.mesh, name: store.partName)
        dataURL = store.exportData()
    }
}

/// グラフィックス領域で当たった面
struct SceneHit {
    var point: Vec3
    var triangle: Int
}
