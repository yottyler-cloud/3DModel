import SwiftUI

struct ContentView: View {
    @StateObject private var editor = Editor(store: ModelStore())
    @StateObject private var keypad = Keypad()

    var body: some View {
        Workspace()
            .environmentObject(editor)
            .environmentObject(editor.store)
            .environmentObject(keypad)
    }
}

/// 上にコマンド、左にツリー/PropertyManager、右にグラフィックス領域
struct Workspace: View {
    static var demoSectionPending = ProcessInfo.processInfo.arguments.contains("-demoSection")
        || ProcessInfo.processInfo.arguments.contains("-demoSectionKeep")
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore
    @EnvironmentObject var keypad: Keypad

    var body: some View {
        VStack(spacing: 0) {
            CommandBar()
            Divider()
            HStack(spacing: 0) {
                LeftPanel()
                    .frame(width: 262)
                Divider()
                GraphicsArea()
            }
        }
        .onChange(of: editor.sketch?.dimension?.id) { id in
            // スマート寸法: テンキーで値を入れる
            guard id != nil, let d = editor.sketch?.dimension else { return }
            let editor = self.editor
            keypad.open(key: "寸法", title: "寸法: \(d.title)", value: Double(d.text) ?? 0, live: false,
                        apply: { v in
                            editor.sketch?.dimension?.text = Format.mm(v)
                            editor.sketch?.applyDimension()
                        },
                        onClose: { editor.sketch?.dimension = nil })
        }
        .onChange(of: store.meshVersion) { _ in
            editor.refreshExport()
            if editor.section != nil { editor.updateSection() }
            // Mac での確認用: 起動オプション -demoSection で、最初から断面表示にする
            if Workspace.demoSectionPending && !store.mesh.positions.isEmpty {
                Workspace.demoSectionPending = false
                editor.toggleSection()
                if ProcessInfo.processInfo.arguments.contains("-demoSectionKeep") { editor.confirmSection() }
            }
        }
        .onAppear { editor.refreshExport() }
    }
}

/// 3D表示と、その上に重ねるもの
struct GraphicsArea: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore

    @StateObject private var triad = ViewTriad()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ModelSceneView(
                    mesh: editor.section != nil ? (editor.sectionMesh ?? store.mesh) : store.mesh,
                    meshVersion: editor.displayVersion,
                    showEdges: editor.showEdges,
                    overlays: overlays,
                    viewCommand: editor.viewCommand,
                    sketchCamera: sketchCamera,
                    edgeCandidates: editor.edgeCandidates(),
                    onTap: { face, edge in editor.tapped(face: face, edge: edge) },
                    triad: triad)

                if editor.sketch != nil {
                    SketchOverlay()
                }

                VStack {
                    HStack(alignment: .top) {
                        Spacer()
                        HeadsUpBar()
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        TriadView(triad: triad)
                        Spacer()
                    }
                    StatusBar()
                }
                .padding(10)

                VStack {
                    HStack {
                        Spacer()
                        ConfirmationCorner()
                    }
                    Spacer()
                }
                .padding(10)

                if editor.section != nil && editor.sketch == nil {
                    VStack {
                        HStack {
                            if editor.sectionPanelOpen {
                                SectionPanel()
                            } else {
                                SectionChip()
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.top, 62)
                    .padding(.leading, 10)
                }
            }
            .onAppear { editor.canvasSize = geo.size }
            .onChange(of: geo.size) { editor.canvasSize = $0 }
        }
        .clipped()
    }

    private var sketchCamera: SketchCamera? {
        guard let s = editor.sketch, editor.canvasSize.width > 10 else { return nil }
        let f = s.cameraFrame(editor.canvasSize)
        return SketchCamera(plane: s.plane, center: f.center, halfHeight: f.halfHeight)
    }

    private var overlays: SceneOverlays {
        var o = SceneOverlays()
        if editor.section != nil { o.sectionCaps = editor.sectionCaps }
        if editor.sketch != nil { return o }
        // まだ使っていないスケッチは青で表示
        for f in store.featuresForBuild() where f.kind == .sketch {
            o.sketches.append(.init(plane: f.sketch.plane, shapes: f.sketch.shapes,
                                    emphasized: editor.selection == .feature(f.id)))
        }
        if let s = editor.session {
            if s.draft.kind == .shell {
                o.selectedEdges = editor.capOutlines(s.draft.filletEdges)
            } else if s.draft.kind.isEdgeFeature {
                o.selectedEdges = editor.edges(of: s.draft.filletEdges, excluding: s.draft.id)
            } else {
                o.sketches.append(.init(plane: s.draft.sketch.plane, shapes: s.draft.sketch.shapes, emphasized: true))
                if s.draft.kind.isRevolve, let axis = editor.axisEdge(s.draft) {
                    o.selectedEdges = [axis]
                }
            }
            return o
        }
        switch editor.selection {
        case .refPlane(let p)?:
            o.plane = p.plane
        case .face(_, let tris)?:
            o.faceTriangles = tris
        case .feature(let id)?:
            if let f = store.feature(id) {
                if f.kind == .shell {
                    o.selectedEdges = editor.capOutlines(f.filletEdges)
                } else if f.kind.isEdgeFeature {
                    o.selectedEdges = editor.edges(of: f.filletEdges, excluding: f.id)
                } else if f.kind != .sketch {
                    o.sketches.append(.init(plane: f.sketch.plane, shapes: f.sketch.shapes, emphasized: true))
                }
            }
        case nil:
            break
        }
        return o
    }
}

/// スケッチ中に重ねる2D画面(作図の入力を受け取る)
struct SketchOverlay: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                guard let s = editor.sketch else { return }
                drawing(s).draw(&ctx, size: size, vp: s.viewport(size))
            }
            TouchSurface(
                onBegan: { editor.sketchBegan($0) },
                onMoved: { editor.sketchMoved($0) },
                onEnded: { editor.sketchEnded($0) },
                onCancelled: { editor.sketchCancelled() },
                onPan: { editor.sketchPan($0) },
                onPinch: { s, c in editor.sketchPinch(s, c) })
        }
    }

    private func drawing(_ s: SketchSession) -> SketchDrawing {
        var preview: SketchShape?
        if let a = s.dragStart, let b = s.dragCurrent {
            switch s.tool {
            case .cornerRect: preview = .rectangle(a, b)
            case .centerRect: preview = .centerRectangle(center: a, corner: b)
            case .circle: preview = .circle(center: a, radius: a.distance(to: b))
            default: break
            }
        }
        let env = editor.sketchEnv()
        return SketchDrawing(shapes: s.shapes, references: env.references, selection: s.selection,
                             axisLabels: ("", ""), previewShape: preview,
                             polyPoints: s.polyPoints, cursor: s.cursor ?? s.dragCurrent,
                             highlightCorner: nil, dimensions: s.dimensions,
                             pendingPoint: (s.pointPair?.a ?? s.pointPick).flatMap { DimensionMath.point($0, s.shapes) },
                             pendingPoint2: s.pointPair.flatMap { DimensionMath.point($0.b, s.shapes) })
    }
}

/// グラフィックス領域の上の表示ツール
struct HeadsUpBar: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if editor.sketch != nil { editor.sketchFit() } else { editor.show(.fit) }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            Menu {
                Button("等角") { editor.show(.iso) }
                Button("正面") { editor.show(.front) }
                Button("背面") { editor.show(.back) }
                Button("左側面") { editor.show(.left) }
                Button("右側面") { editor.show(.right) }
                Button("平面(上)") { editor.show(.top) }
                Button("底面") { editor.show(.bottom) }
                if let p = editor.selection?.sketchPlane {
                    Button("垂直表示(選択した面)") { editor.show(.normal(p)) }
                }
            } label: {
                Image(systemName: "cube.transparent")
            }
            .disabled(editor.sketch != nil)
            Button {
                editor.showEdges.toggle()
            } label: {
                Image(systemName: editor.showEdges ? "cube.fill" : "cube")
            }
            .disabled(editor.sketch != nil)
            Button {
                editor.toggleSection()
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(editor.section != nil ? Color.orange : Color.accentColor)
            }
            .disabled(editor.sketch != nil)
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
    }
}

/// 右上の確定(✓)・取消(✗)
struct ConfirmationCorner: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        if editor.sketch != nil {
            VStack(spacing: 10) {
                Button { editor.exitSketch(accept: true) } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.title3).foregroundStyle(.blue)
                }
                Button { editor.exitSketch(accept: false) } label: {
                    Image(systemName: "xmark").font(.title3).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if editor.session != nil {
            VStack(spacing: 10) {
                Button { editor.confirmFeature() } label: {
                    Image(systemName: "checkmark").font(.title3.bold()).foregroundStyle(.green)
                }
                Button { editor.cancelFeature() } label: {
                    Image(systemName: "xmark").font(.title3).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if editor.awaiting != nil {
            Button { editor.awaiting = nil } label: {
                Image(systemName: "xmark").font(.title3).foregroundStyle(.red)
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// 下の案内とメッセージ
struct StatusBar: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = editor.toast {
                Label(t, systemImage: "info.circle")
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            ForEach(store.messages, id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                if store.isBuilding { ProgressView().controlSize(.small) }
                Text(editor.prompt)
                Spacer()
                if !store.mesh.bounds.isEmpty && editor.sketch == nil {
                    let s = store.mesh.bounds.size
                    if store.bodyCount > 1 {
                        Text("ボディ \(store.bodyCount)").foregroundStyle(.secondary)
                    }
                    Text("\(r(s.x)) × \(r(s.y)) × \(r(s.z)) mm").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .font(.caption)
    }

    private func r(_ v: Double) -> String { Format.mm((v * 10).rounded() / 10) }
}

/// 断面表示の設定パネル
struct SectionPanel: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        let s = editor.section
        let range = s.map { editor.sectionRange($0.plane) } ?? -50...50
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.split.2x1").foregroundStyle(.orange)
                Text("断面表示").font(.subheadline.bold())
                Spacer()
                Button {
                    editor.confirmSection()
                } label: {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                }
                Button {
                    editor.endSection()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.red)
                }
            }
            Picker("平面", selection: Binding(get: { s?.kind ?? 0 }, set: { editor.setSectionKind($0) })) {
                Text("正面").tag(0)
                Text("平面").tag(1)
                Text("右側面").tag(2)
                if editor.sectionPlane(3) != nil { Text("選択面").tag(3) }
            }
            .pickerStyle(.segmented)
            Slider(value: Binding(get: { min(max(s?.offset ?? 0, range.lowerBound), range.upperBound) },
                                  set: { editor.section?.offset = ($0 * 10).rounded() / 10 }),
                   in: range)
            HStack {
                Text("位置").font(.footnote)
                Spacer()
                KeypadButton(key: "断面の位置", title: "断面の位置", value: Binding(
                    get: { editor.section?.offset ?? 0 }, set: { editor.section?.offset = $0 }), width: 80)
                Text("mm").font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("反対側を表示", isOn: Binding(get: { s?.flip ?? false }, set: { editor.section?.flip = $0 }))
                .font(.footnote)
            Text("✓ で断面の見た目をそのまま保持します(部品と一緒に保存)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 断面を保持しているときの小さな表示(編集・解除)
struct SectionChip: View {
    @EnvironmentObject var editor: Editor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1").foregroundStyle(.orange)
            Text("断面表示中").font(.footnote.bold())
            if let s = editor.section {
                Text("\(s.plane.name) \(Format.mm(s.offset)) mm").font(.caption).foregroundStyle(.secondary)
            }
            Button("編集") { editor.sectionPanelOpen = true }
                .font(.footnote)
            Button("解除") { editor.endSection() }
                .font(.footnote)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }
}
