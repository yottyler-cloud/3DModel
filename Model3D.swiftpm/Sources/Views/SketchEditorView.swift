import SwiftUI

/// 2次元スケッチを描いて、押し出し・引き抜きの条件を決める画面
struct SketchEditorView: View {
    @EnvironmentObject var store: ModelStore
    @State var draft: Feature
    var onFinish: (Feature?) -> Void

    init(draft: Feature, onFinish: @escaping (Feature?) -> Void) {
        _draft = State(initialValue: draft)
        self.onFinish = onFinish
    }

    @State private var tool: SketchTool = .rectangle
    @State private var scale: CGFloat = 5
    @State private var pan: CGSize = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var selection: UUID?
    @State private var dragStart: Vec2?
    @State private var dragCurrent: Vec2?
    @State private var polyPoints: [Vec2] = []
    @State private var cursor: Vec2?
    @State private var moveAnchor: Vec2?
    @State private var moveOriginal: SketchShape?
    @State private var cornerR: Double = 3
    @State private var snapToGrid = true
    @State private var undoStack: [[SketchShape]] = []
    @State private var didFit = false

    private var viewport: SketchViewport {
        SketchViewport(scale: scale,
                       origin: CGPoint(x: canvasSize.width / 2 + pan.width,
                                       y: canvasSize.height / 2 + pan.height))
    }

    /// 同じ向きの平面にある、ほかの特徴のスケッチ(参照用)
    private var references: [SketchShape] {
        store.features
            .filter { $0.id != draft.id && !$0.suppressed && $0.sketch.plane.kind == draft.sketch.plane.kind }
            .flatMap { $0.sketch.shapes }
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                canvasArea
                Divider()
                SketchInspector(draft: $draft, selection: $selection, cornerR: $cornerR,
                                snapToGrid: $snapToGrid, pushUndo: pushUndo)
                    .frame(width: 340)
            }
            .navigationTitle(draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { onFinish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        finishPolygon()
                        onFinish(draft)
                    }
                    .bold()
                    .disabled(!draft.sketch.shapes.contains { $0.isValid })
                }
            }
        }
    }

    // MARK: 作図エリア

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    drawing.draw(&ctx, size: size, vp: viewport)
                }
                TouchSurface(
                    onBegan: { began($0) },
                    onMoved: { moved($0) },
                    onEnded: { ended($0) },
                    onCancelled: { cancelInProgress() },
                    onPan: { d in pan.width += d.width; pan.height += d.height },
                    onPinch: { s, c in zoom(by: s, around: c) })
                toolBar
                    .padding(.top, 10)
            }
            .onAppear {
                canvasSize = geo.size
                if !didFit { didFit = true; fitAll() }
            }
            .onChange(of: geo.size) { canvasSize = $0 }
        }
        .background(Color(uiColor: .systemBackground))
        .clipped()
    }

    private var toolBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(SketchTool.allCases) { t in
                    Button {
                        finishPolygon()
                        tool = t
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol).font(.title3)
                            Text(t.label).font(.caption2)
                        }
                        .frame(width: 64, height: 46)
                        .background(tool == t ? Color.accentColor.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider().frame(height: 36)
                Button { undo() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.uturn.backward").font(.title3)
                        Text("戻す").font(.caption2)
                    }.frame(width: 52, height: 46)
                }
                .disabled(undoStack.isEmpty && polyPoints.isEmpty)
                Button { fitAll() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
                        Text("全体").font(.caption2)
                    }.frame(width: 52, height: 46)
                }
            }
            .padding(6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(tool.hint)
                if tool == .polygon && polyPoints.count >= 3 {
                    Button("閉じる") { finishPolygon() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if tool == .fillet {
                    Text("R = \(Format.mm(cornerR)) mm").bold()
                }
            }
            .font(.footnote)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.thinMaterial)
            .clipShape(Capsule())
        }
    }

    private var drawing: SketchDrawing {
        var preview: SketchShape?
        if let a = dragStart, let b = dragCurrent {
            switch tool {
            case .rectangle: preview = .rectangle(a, b)
            case .circle: preview = .circle(center: a, radius: a.distance(to: b))
            default: break
            }
        }
        return SketchDrawing(shapes: draft.sketch.shapes, references: references, selection: selection,
                             axisLabels: draft.sketch.plane.kind.axisLabels, previewShape: preview,
                             polyPoints: polyPoints, cursor: cursor ?? dragCurrent,
                             highlightCorner: nil)
    }

    // MARK: 入力

    private func began(_ s: CGPoint) {
        switch tool {
        case .rectangle, .circle:
            let p = snap(s)
            dragStart = p
            dragCurrent = p
        case .polygon:
            cursor = snap(s)
        case .select:
            selection = hitShape(s)
            if let id = selection, let shape = draft.sketch.shapes.first(where: { $0.id == id }) {
                moveAnchor = viewport.toWorld(s)
                moveOriginal = shape
            }
        case .fillet:
            break
        }
    }

    private func moved(_ s: CGPoint) {
        switch tool {
        case .rectangle, .circle:
            if dragStart != nil { dragCurrent = snap(s) }
        case .polygon:
            cursor = snap(s)
        case .select:
            guard let anchor = moveAnchor, let original = moveOriginal,
                  let i = draft.sketch.shapes.firstIndex(where: { $0.id == original.id }) else { return }
            if draft.sketch.shapes[i] == original && undoStack.last != draft.sketch.shapes {
                pushUndo()
            }
            var d = viewport.toWorld(s) - anchor
            // 図形の基準点(最初の点)をスナップ先へ合わせる
            let ref = original.points[0]
            let target = snapWorld(ref + d, excluding: original.id)
            d = target - ref
            var moved = original
            moved.translate(by: d)
            draft.sketch.shapes[i] = moved
        case .fillet:
            break
        }
    }

    private func ended(_ s: CGPoint) {
        switch tool {
        case .rectangle:
            if let a = dragStart {
                let b = snap(s)
                if abs(a.x - b.x) > 1e-6 && abs(a.y - b.y) > 1e-6 {
                    addShape(.rectangle(a, b))
                }
            }
            dragStart = nil; dragCurrent = nil
        case .circle:
            if let a = dragStart {
                let r = a.distance(to: snap(s))
                if r > 1e-6 { addShape(.circle(center: a, radius: (r * 1000).rounded() / 1000)) }
            }
            dragStart = nil; dragCurrent = nil
        case .polygon:
            let p = snap(s)
            if polyPoints.count >= 3,
               hypot(viewport.toScreen(polyPoints[0]).x - s.x, viewport.toScreen(polyPoints[0]).y - s.y) < 22 {
                finishPolygon()
            } else if polyPoints.last.map({ $0.distance(to: p) > 1e-6 }) ?? true {
                polyPoints.append(p)
            }
            cursor = nil
        case .select:
            moveAnchor = nil
            moveOriginal = nil
        case .fillet:
            toggleFillet(at: s)
        }
    }

    private func cancelInProgress() {
        dragStart = nil
        dragCurrent = nil
        cursor = nil
        if let original = moveOriginal,
           let i = draft.sketch.shapes.firstIndex(where: { $0.id == original.id }) {
            draft.sketch.shapes[i] = original
        }
        moveAnchor = nil
        moveOriginal = nil
    }

    private func finishPolygon() {
        if polyPoints.count >= 3 {
            let shape = SketchShape.polygon(polyPoints)
            if shape.isValid { addShape(shape) }
        }
        polyPoints = []
        cursor = nil
    }

    private func addShape(_ shape: SketchShape) {
        pushUndo()
        draft.sketch.shapes.append(shape)
        selection = shape.id
    }

    private func pushUndo() {
        undoStack.append(draft.sketch.shapes)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func undo() {
        if !polyPoints.isEmpty {
            polyPoints.removeLast()
            return
        }
        guard let last = undoStack.popLast() else { return }
        draft.sketch.shapes = last
        if let s = selection, !last.contains(where: { $0.id == s }) { selection = nil }
    }

    private func toggleFillet(at s: CGPoint) {
        var best: (shape: Int, corner: Int, d: CGFloat)?
        for (si, shape) in draft.sketch.shapes.enumerated() {
            for (ci, c) in shape.corners.enumerated() {
                let sp = viewport.toScreen(c)
                let d = hypot(sp.x - s.x, sp.y - s.y)
                if d < 28 && d < (best?.d ?? .infinity) { best = (si, ci, d) }
            }
        }
        guard let b = best else { return }
        pushUndo()
        let current = draft.sketch.shapes[b.shape].radius(at: b.corner)
        let newR = abs(current - cornerR) < 1e-9 ? 0 : cornerR
        draft.sketch.shapes[b.shape].setRadius(newR, at: b.corner)
        selection = draft.sketch.shapes[b.shape].id
    }

    // MARK: スナップ

    private func snap(_ s: CGPoint) -> Vec2 {
        snapWorld(viewport.toWorld(s), excluding: nil)
    }

    private func snapWorld(_ w: Vec2, excluding: UUID?) -> Vec2 {
        let vp = viewport
        let sp = vp.toScreen(w)
        var candidates: [Vec2] = [.zero]
        for shape in draft.sketch.shapes where shape.id != excluding { candidates += shape.snapPoints }
        for shape in references { candidates += shape.snapPoints }
        candidates += polyPoints
        var best: Vec2?
        var bestD: CGFloat = 14
        for c in candidates {
            let cs = vp.toScreen(c)
            let d = hypot(cs.x - sp.x, cs.y - sp.y)
            if d < bestD { bestD = d; best = c }
        }
        if let best { return best }
        if snapToGrid {
            let step = vp.gridStep
            return Vec2((w.x / step).rounded() * step, (w.y / step).rounded() * step)
        }
        return Vec2((w.x * 1000).rounded() / 1000, (w.y * 1000).rounded() / 1000)
    }

    private func hitShape(_ s: CGPoint) -> UUID? {
        let w = viewport.toWorld(s)
        let tol = Double(12 / scale)
        // 線の近くを優先し、次に内側(小さい図形を優先)
        var best: (UUID, Double)?
        for shape in draft.sketch.shapes where shape.isValid {
            let pts = ProfileGeometry.outline(shape)
            let d = Polygon2D.distanceToOutline(pts, w)
            if d < tol && d < (best?.1 ?? .infinity) { best = (shape.id, d) }
        }
        if let best { return best.0 }
        var inside: (UUID, Double)?
        for shape in draft.sketch.shapes where shape.isValid {
            let pts = ProfileGeometry.outline(shape)
            if Polygon2D.contains(pts, w) {
                let area = abs(Polygon2D.signedArea(pts))
                if area < (inside?.1 ?? .infinity) { inside = (shape.id, area) }
            }
        }
        return inside?.0
    }

    // MARK: 表示

    private func zoom(by s: CGFloat, around c: CGPoint) {
        let before = viewport.toWorld(c)
        scale = min(max(scale * s, 0.05), 400)
        let after = viewport.toScreen(before)
        pan.width += c.x - after.x
        pan.height += c.y - after.y
    }

    private func fitAll() {
        var pts: [Vec2] = []
        for s in draft.sketch.shapes + references where s.isValid { pts += ProfileGeometry.outline(s) }
        if pts.isEmpty { pts = [Vec2(-50, -50), Vec2(50, 50)] }
        pts.append(.zero)
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let size = canvasSize == .zero ? CGSize(width: 600, height: 600) : canvasSize
        scale = min((size.width - 80) / CGFloat(w), (size.height - 200) / CGFloat(h))
        scale = min(max(scale, 0.05), 400)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        // 中心が画面の中央(上のツールバーの分だけ下)に来るように
        pan = CGSize(width: -CGFloat(cx) * scale, height: CGFloat(cy) * scale + 40)
    }
}

// MARK: - 右側の設定パネル

struct SketchInspector: View {
    @EnvironmentObject var store: ModelStore
    @Binding var draft: Feature
    @Binding var selection: UUID?
    @Binding var cornerR: Double
    @Binding var snapToGrid: Bool
    var pushUndo: () -> Void

    var body: some View {
        Form {
            Section("特徴") {
                TextField("名前", text: $draft.name)
                Picker("種類", selection: $draft.kind) {
                    Text("押し出し").tag(FeatureKind.extrude)
                    Text("引き抜き").tag(FeatureKind.cut)
                }
                .pickerStyle(.segmented)
            }

            Section("スケッチ平面") {
                Picker("平面", selection: $draft.sketch.plane.kind) {
                    ForEach(SketchPlaneKind.allCases) { Text($0.label).tag($0) }
                }
                NumberField(label: "オフセット", value: $draft.sketch.plane.offset)
                HStack {
                    Button("形の上端へ") {
                        draft.sketch.plane.offset = store.extremeAlongNormal(draft.sketch.plane.kind, max: true)
                    }
                    Spacer()
                    Button("形の下端へ") {
                        draft.sketch.plane.offset = store.extremeAlongNormal(draft.sketch.plane.kind, max: false)
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }

            Section(draft.kind == .extrude ? "押し出し" : "引き抜き") {
                Picker("方向", selection: $draft.direction) {
                    ForEach(ExtentDirection.allCases) { Text($0.label).tag($0) }
                }
                if draft.kind == .cut {
                    Toggle("貫通", isOn: $draft.throughAll)
                }
                if !(draft.kind == .cut && draft.throughAll) {
                    NumberField(label: "距離", value: $draft.distance)
                }
            }

            Section {
                NumberField(label: "スケッチ面側のR", value: $draft.startFillet)
                NumberField(label: "先端側のR", value: $draft.endFillet)
            } header: {
                Text("エッジのフィレット")
            } footer: {
                Text(draft.kind == .extrude
                     ? "押し出した形の、スケッチ面側と先端側のふちを丸めます。"
                     : "引き抜きの入口(スケッチ面側)のふちと、底(先端側)のすみを丸めます。")
            }

            Section {
                NumberField(label: "角R(タップでつける値)", value: $cornerR)
                Button("すべての角に R\(Format.mm(cornerR)) をつける") {
                    pushUndo()
                    for i in draft.sketch.shapes.indices { draft.sketch.shapes[i].setAllRadii(cornerR) }
                }
                Button("すべての角Rを外す") {
                    pushUndo()
                    for i in draft.sketch.shapes.indices { draft.sketch.shapes[i].setAllRadii(0) }
                }
                Toggle("格子にスナップ", isOn: $snapToGrid)
            } header: {
                Text("角のフィレット(スケッチ)")
            }

            if let current = draft.sketch.shapes.first(where: { $0.id == selection }) {
                // 削除のあとに古い番号で読まないよう、idで探すBindingにする
                let id = current.id
                ShapeEditorSection(shape: Binding(
                    get: { draft.sketch.shapes.first { $0.id == id } ?? current },
                    set: { new in
                        if let j = draft.sketch.shapes.firstIndex(where: { $0.id == id }) {
                            draft.sketch.shapes[j] = new
                        }
                    })) {
                    pushUndo()
                    selection = nil
                    draft.sketch.shapes.removeAll { $0.id == id }
                }
            }

            Section("図形 (\(draft.sketch.shapes.count))") {
                if draft.sketch.shapes.isEmpty {
                    Text("左の画面に図形を描いてください").foregroundStyle(.secondary)
                }
                ForEach(draft.sketch.shapes) { s in
                    Button {
                        selection = s.id
                    } label: {
                        HStack {
                            Text(s.kind.label)
                            Spacer()
                            Text(shapeSummary(s)).foregroundStyle(.secondary).font(.footnote)
                        }
                    }
                    .foregroundStyle(s.id == selection ? Color.orange : Color.primary)
                }
                .onDelete { idx in
                    pushUndo()
                    selection = nil
                    draft.sketch.shapes.remove(atOffsets: idx)
                }
            }
        }
    }

    private func shapeSummary(_ s: SketchShape) -> String {
        switch s.kind {
        case .rectangle: return "\(Format.mm(s.rectSize.x)) × \(Format.mm(s.rectSize.y))"
        case .circle: return "⌀\(Format.mm(s.radius * 2))"
        case .polygon: return "\(s.points.count) 頂点"
        }
    }
}

/// 選択した図形の数値編集
struct ShapeEditorSection: View {
    @Binding var shape: SketchShape
    var onDelete: () -> Void

    var body: some View {
        Section("選択中: \(shape.kind.label)") {
            switch shape.kind {
            case .rectangle:
                NumberField(label: "左下 X", value: Binding(
                    get: { shape.rectMin.x },
                    set: { shape.setRect(origin: Vec2($0, shape.rectMin.y), size: shape.rectSize) }))
                NumberField(label: "左下 Y", value: Binding(
                    get: { shape.rectMin.y },
                    set: { shape.setRect(origin: Vec2(shape.rectMin.x, $0), size: shape.rectSize) }))
                NumberField(label: "幅", value: Binding(
                    get: { shape.rectSize.x },
                    set: { shape.setRect(origin: shape.rectMin, size: Vec2($0, shape.rectSize.y)) }))
                NumberField(label: "高さ", value: Binding(
                    get: { shape.rectSize.y },
                    set: { shape.setRect(origin: shape.rectMin, size: Vec2(shape.rectSize.x, $0)) }))
                cornerFields
            case .circle:
                NumberField(label: "中心 X", value: Binding(
                    get: { shape.points[0].x }, set: { shape.points[0].x = $0 }))
                NumberField(label: "中心 Y", value: Binding(
                    get: { shape.points[0].y }, set: { shape.points[0].y = $0 }))
                NumberField(label: "直径", value: Binding(
                    get: { shape.radius * 2 }, set: { shape.radius = max($0 / 2, 0.001) }))
            case .polygon:
                ForEach(shape.points.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1)").frame(width: 22).foregroundStyle(.secondary)
                        CompactNumber(prefix: "X", value: Binding(
                            get: { shape.points[i].x }, set: { shape.points[i].x = $0 }))
                        CompactNumber(prefix: "Y", value: Binding(
                            get: { shape.points[i].y }, set: { shape.points[i].y = $0 }))
                        CompactNumber(prefix: "R", value: Binding(
                            get: { shape.radius(at: i) }, set: { shape.setRadius($0, at: i) }))
                    }
                }
            }
            Button("この図形を削除", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var cornerFields: some View {
        let names = ["左下", "右下", "右上", "左上"]
        ForEach(0..<4, id: \.self) { i in
            NumberField(label: "\(names[i])の角R", value: Binding(
                get: { shape.radius(at: i) }, set: { shape.setRadius($0, at: i) }))
        }
    }
}

/// ラベル付きの数値入力(mm)
struct NumberField: View {
    var label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            Text("mm").foregroundStyle(.secondary).font(.footnote)
        }
    }
}

struct CompactNumber: View {
    var prefix: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 2) {
            Text(prefix).font(.caption).foregroundStyle(.secondary)
            TextField(prefix, value: $value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
        }
    }
}
