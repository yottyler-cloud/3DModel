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
                    Text("押し出しのふち(スケッチ面側・先端側)、カットの入口と底、角の縦のエッジを選べます。ふちを選ぶと、そのフィーチャーの同じ側のふちがすべて\(isChamfer ? "面取り" : "丸く")になります。")
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
        let hasAxis = draft?.sketch.shapes.contains { $0.kind == .centerline && $0.isValid } ?? false
        VStack(spacing: 0) {
            PMHeader(title: draft?.name ?? "", symbol: kind.symbol,
                     onOK: { editor.confirmFeature() }, onCancel: { editor.cancelFeature() })
            Form {
                Section("名前") {
                    TextField("名前", text: editor.draft(\.name, ""))
                }
                Section {
                    if hasAxis {
                        Label("スケッチの中心線", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("中心線がありません", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("スケッチを編集して中心線を描く") {
                            if let id = editor.session?.replacing {
                                editor.cancelFeature()
                                editor.editSketch(id)
                                editor.sketch?.tool = .centerline
                            }
                        }
                    }
                } header: {
                    Text("回転軸")
                } footer: {
                    Text("輪郭は中心線の片側に描きます。中心線に接していてもかまいません。")
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
