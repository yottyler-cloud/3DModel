import SwiftUI

/// 左側のパネル: コマンド中は PropertyManager、それ以外はフィーチャーツリー
struct LeftPanel: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var keypad: Keypad

    /// パネルの中身が変わったらテンキーを閉じる
    private var panelState: String {
        if let s = editor.sketch { return "sketch-\(s.selection?.uuidString ?? "")" }
        if let s = editor.session { return "session-\(s.draft.id)" }
        return "tree"
    }

    var body: some View {
        Group {
            if editor.sketch != nil {
                SketchPropertyManager()
            } else if let s = editor.session {
                if s.draft.kind.isEdgeFeature {
                    FilletPropertyManager()
                } else if s.draft.kind.isRevolve {
                    RevolvePropertyManager()
                } else {
                    ExtrudePropertyManager()
                }
            } else {
                FeatureTree()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keypad.isOpen { KeypadView(keypad: keypad) }
        }
        .onChange(of: panelState) { _ in
            if keypad.activeKey != "寸法" || editor.sketch == nil { keypad.close() }
        }
    }
}

/// 押し出し・押し出しカット
struct ExtrudePropertyManager: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        let draft = editor.session?.draft
        let kind = draft?.kind ?? .extrude
        VStack(spacing: 0) {
            PMHeader(title: draft?.name ?? "", symbol: kind.symbol,
                     onOK: { editor.confirmFeature() }, onCancel: { editor.cancelFeature() })
            Form {
                Section("名前") {
                    TextField("名前", text: editor.draft(\.name, ""))
                }
                Section("開始条件") {
                    Picker("開始", selection: editor.draft(\.useStartOffset, false)) {
                        Text("スケッチ平面").tag(false)
                        Text("オフセット").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if draft?.useStartOffset == true {
                        NumberField(label: "オフセット距離", value: editor.draft(\.startOffset, 0))
                    }
                }
                Section("方向 1") {
                    Picker("終了条件", selection: editor.draft(\.endCondition, .blind)) {
                        ForEach(EndCondition.allCases.filter { $0 != .throughAll || kind == .cut }) {
                            Text($0.label).tag($0)
                        }
                    }
                    if draft?.endCondition != .midPlane {
                        Button {
                            editor.session?.draft.reversed.toggle()
                        } label: {
                            Label("反対方向", systemImage: "arrow.up.arrow.down")
                        }
                        .foregroundStyle(draft?.reversed == true ? Color.orange : Color.accentColor)
                    }
                    if !(kind == .cut && draft?.endCondition == .throughAll) {
                        NumberField(label: "深さ", value: editor.draft(\.distance, 10))
                        Stepper("1 mm ずつ", onIncrement: {
                            editor.session?.draft.distance += 1
                        }, onDecrement: {
                            if let d = editor.session?.draft.distance, d > 1 { editor.session?.draft.distance = d - 1 }
                        })
                    }
                }
                if kind == .extrude {
                    Section {
                        Toggle("元の形とつなげる(結果をマージ)", isOn: editor.draft(\.mergeResult, true))
                    } header: {
                        Text("ボディ")
                    } footer: {
                        Text(draft?.mergeResult ?? true
                             ? "触れている形と1つのボディになります。付け根のフィレットは元の面へなだらかにつながります。"
                             : "元の形とつなげず、別のボディとして作ります。")
                    }
                }
                Section("スケッチ") {
                    LabeledContent("使うスケッチ", value: draft?.sketchName ?? "")
                    LabeledContent("平面", value: draft?.sketch.plane.name ?? "")
                    LabeledContent("図形", value: "\(draft?.sketch.shapes.count ?? 0)")
                }
            }
        }
    }
}

/// フィレット(固定サイズ)
struct FilletPropertyManager: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        let draft = editor.session?.draft
        let kind = draft?.kind ?? .fillet
        let isChamfer = kind == .chamfer
        VStack(spacing: 0) {
            PMHeader(title: draft?.name ?? "", symbol: kind.symbol,
                     onOK: { editor.confirmFeature() }, onCancel: { editor.cancelFeature() })
            Form {
                Section(isChamfer ? "面取り パラメータ" : "フィレット パラメータ") {
                    NumberField(label: isChamfer ? "距離 C" : "半径 R", value: editor.draft(\.filletRadius, 3))
                    if isChamfer {
                        Text("両側に同じ長さで45°に面取りします").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if draft?.filletEdges.isEmpty ?? true {
                        Text("グラフィックス領域でエッジをタップしてください")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(draft?.filletEdges ?? [], id: \.self) { e in
                        HStack {
                            Image(systemName: "line.diagonal").foregroundStyle(.orange)
                            Text(editor.describe(e)).font(.callout)
                            Spacer()
                            Button {
                                editor.session?.draft.filletEdges.removeAll { $0 == e }
                            } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !(draft?.filletEdges.isEmpty ?? true) {
                        Button("選択をすべて解除", role: .destructive) {
                            editor.session?.draft.filletEdges.removeAll()
                        }
                    }
                } header: {
                    Text(isChamfer ? "面取りするアイテム" : "フィレットするアイテム")
                } footer: {
                    Text("押し出しの上下のふちの辺、カットの入口と底の辺、角の縦のエッジを選べます。タップした辺だけに\(isChamfer ? "面取り" : "フィレット")がつきます(円は1周で1辺)。")
                }
                Section("名前") {
                    TextField("名前", text: editor.draft(\.name, ""))
                }
            }
        }
    }
}

/// スケッチ中のパネル
struct SketchPropertyManager: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        let s = editor.sketch
        VStack(spacing: 0) {
            PMHeader(title: s?.feature.sketchName ?? "スケッチ", symbol: FeatureKind.sketch.symbol,
                     onOK: { editor.exitSketch(accept: true) }, onCancel: { editor.exitSketch(accept: false) })
            Form {
                Section("スケッチ") {
                    LabeledContent("平面", value: s?.plane.name ?? "")
                    LabeledContent("ツール", value: s?.tool.label ?? "")
                    Text(s?.tool.hint ?? "").font(.footnote).foregroundStyle(.secondary)
                    if s?.tool == .line, (s?.polyPoints.count ?? 0) >= 3 {
                        Button("線を閉じる") { editor.sketch?.finishPolygon() }
                    }
                }

                if s?.tool == .sketchChamfer {
                    Section("スケッチ面取り") {
                        NumberField(label: "距離 C", value: Binding(
                            get: { editor.sketch?.cornerC ?? 2 },
                            set: { editor.sketch?.cornerC = max(0, $0) }))
                        Button("すべての角につける") {
                            if let c = editor.sketch?.cornerC { editor.sketch?.setAllCornerChamfers(c) }
                        }
                        Button("すべての角Cを外す") { editor.sketch?.setAllCornerChamfers(0) }
                    }
                }

                if s?.tool == .sketchFillet {
                    Section("スケッチ フィレット") {
                        NumberField(label: "半径", value: Binding(
                            get: { editor.sketch?.cornerR ?? 3 },
                            set: { editor.sketch?.cornerR = max(0, $0) }))
                        Button("すべての角につける") {
                            if let r = editor.sketch?.cornerR { editor.sketch?.setAllCornerRadii(r) }
                        }
                        Button("すべての角Rを外す") { editor.sketch?.setAllCornerRadii(0) }
                    }
                }

                if let sel = s?.selection, let current = s?.shapes.first(where: { $0.id == sel }) {
                    ShapeEditorSection(shape: Binding(
                        get: { editor.sketch?.shapes.first { $0.id == sel } ?? current },
                        set: { new in
                            if let j = editor.sketch?.shapes.firstIndex(where: { $0.id == sel }) {
                                editor.sketch?.shapes[j] = new
                            }
                        })) {
                        editor.sketch?.deleteShape(sel)
                    }
                }

                if s?.tool == .dimension {
                    Section {
                        if let pair = s?.pointPair, let shapes = s?.shapes {
                            ForEach([DimKind.horizontal(pair.a, pair.b), .vertical(pair.a, pair.b),
                                     .distance(pair.a, pair.b)], id: \.self) { kind in
                                Button {
                                    editor.sketch?.choosePositionDimension(kind)
                                } label: {
                                    HStack {
                                        Text(kind.title)
                                        Spacer()
                                        Text(Format.mm(((DimensionMath.measure(kind, shapeID: pair.b.shapeID ?? UUID(), shapes) ?? 0) * 1000).rounded() / 1000) + " mm")
                                            .font(.body.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button("点の選び直し", role: .cancel) {
                                editor.sketch?.pointPair = nil
                                editor.sketch?.pointPick = nil
                            }
                        } else if s?.pointPick != nil {
                            Text("2つ目の点(原点・角・頂点・円の中心)をタップしてください")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("1つ目の点をタップすると、位置の寸法を付けられます。辺や円をタップすると長さ・直径です。")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("位置の寸法")
                    } footer: {
                        Text("1つ目の点が基準、2つ目の点(の図形)が動きます。原点は動きません。")
                    }
                }

                Section {
                    if (s?.dimensions ?? []).isEmpty {
                        Text("寸法はまだありません").foregroundStyle(.secondary)
                    }
                    ForEach(s?.dimensions ?? []) { d in
                        Button {
                            editor.sketch?.editDimension(d)
                        } label: {
                            HStack {
                                Text(dimensionName(d, s?.shapes ?? []))
                                Spacer()
                                Text((d.kind == .diameter ? "⌀" : "") + Format.mm((d.value * 1000).rounded() / 1000) + " mm")
                                    .font(.body.monospacedDigit())
                            }
                        }
                        .foregroundStyle(Color.primary)
                    }
                    .onDelete { idx in
                        let ids = idx.compactMap { i in editor.sketch?.dimensions[i].id }
                        for id in ids { editor.sketch?.deleteDimension(id) }
                    }
                } header: {
                    Text("寸法")
                } footer: {
                    Text("「スマート寸法」で線や円をタップすると寸法が付きます。図の寸法の数字(または上の一覧)をタップすると値を変えられ、図形がその値に合わせて変わります。左へスワイプで削除。")
                }

                Section("オプション") {
                    Toggle("格子にスナップ", isOn: Binding(
                        get: { editor.sketch?.snapToGrid ?? true },
                        set: { editor.sketch?.snapToGrid = $0 }))
                    Button("スケッチ全体を表示") { editor.sketchFit() }
                }

                Section("図形 (\(s?.shapes.count ?? 0))") {
                    ForEach(s?.shapes ?? []) { shape in
                        Button {
                            editor.sketch?.selection = shape.id
                        } label: {
                            HStack {
                                Text(shape.kind.label)
                                Spacer()
                                Text(summary(shape)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(shape.id == s?.selection ? Color.orange : Color.primary)
                    }
                    .onDelete { idx in
                        let ids = idx.compactMap { i in editor.sketch?.shapes[i].id }
                        for id in ids { editor.sketch?.deleteShape(id) }
                    }
                }
            }
        }
    }

    private func dimensionName(_ d: SketchDimension, _ shapes: [SketchShape]) -> String {
        let shape = shapes.first { $0.id == d.shapeID }
        let n = (shapes.firstIndex { $0.id == d.shapeID } ?? 0) + 1
        let base = "\(shape?.kind.label ?? "図形")\(n)"
        if case .edge(let k) = d.kind { return "\(base) 辺\(k + 1)" }
        if let pair = d.kind.points {
            return "\(pointName(pair.0, shapes))→\(pointName(pair.1, shapes)) \(d.kind.title)"
        }
        return "\(base) \(d.kind.title)"
    }

    private func pointName(_ r: PointRef, _ shapes: [SketchShape]) -> String {
        switch r {
        case .origin: return "原点"
        case .center(let id):
            let n = (shapes.firstIndex { $0.id == id } ?? 0) + 1
            return "円\(n)の中心"
        case .vertex(let id, let k):
            let n = (shapes.firstIndex { $0.id == id } ?? 0) + 1
            let label = shapes.first { $0.id == id }?.kind.label ?? "図形"
            return "\(label)\(n)の点\(k + 1)"
        }
    }

    private func summary(_ s: SketchShape) -> String {
        switch s.kind {
        case .rectangle: return "\(Format.mm(s.rectSize.x)) × \(Format.mm(s.rectSize.y))"
        case .circle: return "⌀\(Format.mm(s.radius * 2))"
        case .polygon: return "\(s.points.count) 頂点"
        case .centerline: return "長さ \(Format.mm(s.points[0].distance(to: s.points[1])))"
        }
    }
}

/// 回転・回転カット
struct RevolvePropertyManager: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        let draft = editor.session?.draft
        let kind = draft?.kind ?? .revolve
        let hasAxis = draft?.revolveAxis != nil
        VStack(spacing: 0) {
            PMHeader(title: draft?.name ?? "", symbol: kind.symbol,
                     onOK: { editor.confirmFeature() }, onCancel: { editor.cancelFeature() })
            Form {
                Section("名前") {
                    TextField("名前", text: editor.draft(\.name, ""))
                }
                Section {
                    if hasAxis, let d = draft {
                        Label(editor.describeAxis(d), systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("未選択", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("回転軸")
                } footer: {
                    Text("グラフィックス領域で、スケッチの線(三角形や長方形の辺、中心線)をタップすると回転軸になります。選んだ軸はオレンジで表示されます。輪郭は軸の片側にあるようにします(軸に接していてもかまいません)。")
                }
                Section("方向 1") {
                    Picker("回転のしかた", selection: Binding(
                        get: { editor.session?.draft.endCondition == .midPlane },
                        set: { editor.session?.draft.endCondition = $0 ? .midPlane : .blind })) {
                        Text("片側").tag(false)
                        Text("両側対称").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if draft?.endCondition != .midPlane {
                        Button {
                            editor.session?.draft.reversed.toggle()
                        } label: {
                            Label("反対方向", systemImage: "arrow.uturn.left.circle")
                        }
                        .foregroundStyle(draft?.reversed == true ? Color.orange : Color.accentColor)
                    }
                    NumberField(label: "角度", value: Binding(
                        get: { editor.session?.draft.distance ?? 360 },
                        set: { editor.session?.draft.distance = min(max($0, 0.1), 360) }), unit: "°")
                    HStack {
                        ForEach([90.0, 180, 270, 360], id: \.self) { a in
                            Button("\(Int(a))°") { editor.session?.draft.distance = a }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if kind == .revolve {
                    Section {
                        Toggle("元の形とつなげる(結果をマージ)", isOn: editor.draft(\.mergeResult, true))
                    } header: {
                        Text("ボディ")
                    }
                }
                Section("スケッチ") {
                    LabeledContent("使うスケッチ", value: draft?.sketchName ?? "")
                    LabeledContent("平面", value: draft?.sketch.plane.name ?? "")
                }
            }
        }
    }
}
