import SwiftUI

struct ContentView: View {
    @StateObject private var editor = Editor(store: ModelStore())

    var body: some View {
        Workspace()
            .environmentObject(editor)
            .environmentObject(editor.store)
    }
}

/// 上にコマンド、左にツリー/PropertyManager、右にグラフィックス領域
struct Workspace: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore

    var body: some View {
        VStack(spacing: 0) {
            CommandBar()
            Divider()
            HStack(spacing: 0) {
                LeftPanel()
                    .frame(width: 310)
                Divider()
                GraphicsArea()
            }
        }
        .alert(editor.sketch?.dimension?.title ?? "寸法",
               isPresented: Binding(get: { editor.sketch?.dimension != nil },
                                    set: { if !$0 { editor.sketch?.dimension = nil } })) {
            TextField("値(mm)", text: Binding(get: { editor.sketch?.dimension?.text ?? "" },
                                             set: { editor.sketch?.dimension?.text = $0 }))
                .keyboardType(.numbersAndPunctuation)
            Button("OK") { editor.sketch?.applyDimension() }
            Button("キャンセル", role: .cancel) { editor.sketch?.dimension = nil }
        } message: {
            Text("新しい値を mm で入力します")
        }
        .onChange(of: store.meshVersion) { _ in editor.refreshExport() }
        .onAppear { editor.refreshExport() }
    }
}

/// 3D表示と、その上に重ねるもの
struct GraphicsArea: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ModelSceneView(
                    mesh: store.mesh,
                    meshVersion: store.meshVersion,
                    showEdges: editor.showEdges,
                    overlays: overlays,
                    viewCommand: editor.viewCommand,
                    sketchCamera: sketchCamera,
                    edgeCandidates: editor.session?.draft.kind == .fillet ? editor.edgeCandidates() : [],
                    onTap: { face, edge in editor.tapped(face: face, edge: edge) })

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
        if editor.sketch != nil { return o }
        // まだ使っていないスケッチは青で表示
        for f in store.featuresForBuild() where f.kind == .sketch {
            o.sketches.append(.init(plane: f.sketch.plane, shapes: f.sketch.shapes,
                                    emphasized: editor.selection == .feature(f.id)))
        }
        if let s = editor.session {
            if s.draft.kind == .fillet {
                o.selectedEdges = editor.edges(of: s.draft.filletEdges, excluding: s.draft.id)
            } else {
                o.sketches.append(.init(plane: s.draft.sketch.plane, shapes: s.draft.sketch.shapes, emphasized: true))
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
                if f.kind == .fillet {
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
                             highlightCorner: nil)
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
        }
        .font(.title3)
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
                        .font(.title2).foregroundStyle(.blue)
                }
                Button { editor.exitSketch(accept: false) } label: {
                    Image(systemName: "xmark").font(.title2).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if editor.session != nil {
            VStack(spacing: 10) {
                Button { editor.confirmFeature() } label: {
                    Image(systemName: "checkmark").font(.title2.bold()).foregroundStyle(.green)
                }
                Button { editor.cancelFeature() } label: {
                    Image(systemName: "xmark").font(.title2).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if editor.awaiting != nil {
            Button { editor.awaiting = nil } label: {
                Image(systemName: "xmark").font(.title2).foregroundStyle(.red)
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
