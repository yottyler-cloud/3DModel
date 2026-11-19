import SwiftUI

struct ContentView: View {
    @StateObject private var store = ModelStore()
    @State private var editing: Feature?
    @State private var showFillet = false
    @State private var fitRequest = 0
    @State private var viewDirection: ModelSceneView.ViewDirection = .iso
    @State private var exportURL: URL?
    @State private var confirmClear = false

    var body: some View {
        NavigationSplitView {
            FeatureListView(editing: $editing)
                .navigationTitle("履歴")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Menu {
                            Button("見本の形に戻す") { store.resetToSample() }
                            Button("すべて消す", role: .destructive) { confirmClear = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .confirmationDialog("すべての特徴を消しますか?", isPresented: $confirmClear) {
                    Button("すべて消す", role: .destructive) { store.clearAll() }
                }
        } detail: {
            ZStack(alignment: .topLeading) {
                ModelSceneView(mesh: store.mesh, meshVersion: store.meshVersion,
                               highlight: store.feature(store.selectedID)?.sketch,
                               fitRequest: fitRequest, viewRequest: viewDirection)
                    .ignoresSafeArea(edges: .bottom)
                statusOverlay
                    .padding(12)
            }
            .toolbar { detailToolbar }
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(store)
        .fullScreenCover(item: $editing) { f in
            SketchEditorView(draft: f) { result in
                if let result { store.upsert(result) }
                editing = nil
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showFillet) {
            FilletSheet()
                .environmentObject(store)
        }
    }

    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                editing = store.newFeature(kind: .extrude)
            } label: {
                Label("押し出し", systemImage: FeatureKind.extrude.symbol)
            }
            Button {
                editing = store.newFeature(kind: .cut)
            } label: {
                Label("引き抜き", systemImage: FeatureKind.cut.symbol)
            }
            .disabled(store.features.isEmpty)
            Button {
                showFillet = true
            } label: {
                Label("フィレット", systemImage: "app.connected.to.app.below.fill")
            }
            .disabled(store.features.isEmpty)
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            Menu {
                Button("等角") { show(.iso) }
                Button("上") { show(.top) }
                Button("正面") { show(.front) }
                Button("右") { show(.right) }
            } label: {
                Label("視点", systemImage: "cube")
            }
            Button {
                show(viewDirection)
            } label: {
                Label("全体表示", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            if let url = exportURL {
                ShareLink(item: url) {
                    Label("STLを共有", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func show(_ d: ModelSceneView.ViewDirection) {
        viewDirection = d
        fitRequest += 1
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if store.isBuilding {
                    ProgressView().controlSize(.small)
                    Text("計算中…")
                } else {
                    Text("三角形 \(store.mesh.triangleCount)")
                    if !store.mesh.bounds.isEmpty {
                        let s = store.mesh.bounds.size
                        Text("  大きさ \(Format.mm(round1(s.x))) × \(Format.mm(round1(s.y))) × \(Format.mm(round1(s.z))) mm")
                    }
                }
            }
            ForEach(store.messages, id: \.self) { m in
                Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: store.meshVersion) { _ in
            exportURL = try? STLExporter.writeTemporary(store.mesh)
        }
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

/// 履歴(特徴の一覧)
struct FeatureListView: View {
    @EnvironmentObject var store: ModelStore
    @Binding var editing: Feature?

    var body: some View {
        List(selection: $store.selectedID) {
            if store.features.isEmpty {
                Text("右上の「押し出し」から始めます。\nスケッチ(2次元の図)を描いて、厚みをつけます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.features.enumerated()), id: \.element.id) { index, f in
                HStack {
                    Image(systemName: f.kind.symbol)
                        .foregroundStyle(f.kind == .extrude ? Color.accentColor : Color.pink)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).strikethrough(f.suppressed)
                        Text("\(f.sketch.plane.kind.axisLabels.0)\(f.sketch.plane.kind.axisLabels.1)面  \(f.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        editing = f
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
                .opacity(f.suppressed ? 0.45 : 1)
                .tag(f.id)
                .contextMenu {
                    Button("編集") { editing = f }
                    Button(f.suppressed ? "有効にする" : "一時的に無効") { store.toggleSuppressed(f.id) }
                    Button("上へ") { store.move(f.id, by: -1) }.disabled(index == 0)
                    Button("下へ") { store.move(f.id, by: 1) }.disabled(index == store.features.count - 1)
                    Button("削除", role: .destructive) { store.delete(f.id) }
                }
                .swipeActions {
                    Button("削除", role: .destructive) { store.delete(f.id) }
                }
            }
        }
    }
}

/// フィレット: すでにある押し出し・引き抜きのふちや角を丸める
struct FilletSheet: View {
    @EnvironmentObject var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var startR: Double = 0
    @State private var endR: Double = 2
    @State private var cornerR: Double = 0
    @State private var applyCorners = false

    var body: some View {
        NavigationStack {
            Form {
                Section("対象") {
                    Picker("特徴", selection: $targetID) {
                        ForEach(store.features) { f in
                            Text(f.name).tag(Optional(f.id))
                        }
                    }
                }
                if let f = store.feature(targetID) {
                    Section {
                        NumberField(label: "スケッチ面側のR", value: $startR)
                        NumberField(label: "先端側のR", value: $endR)
                    } header: {
                        Text("エッジのフィレット")
                    } footer: {
                        Text(f.kind == .extrude
                             ? "押し出した形のふち(スケッチ面側・先端側)を丸めます。0で丸めません。"
                             : "引き抜きの入口のふち(スケッチ面側)と、底のすみ(先端側)を丸めます。")
                    }
                    Section {
                        Toggle("スケッチの角もすべて丸める", isOn: $applyCorners)
                        if applyCorners {
                            NumberField(label: "角R", value: $cornerR)
                        }
                    } header: {
                        Text("角(縦のエッジ)のフィレット")
                    } footer: {
                        Text("長方形・多角形のすべての角に同じRをつけます。角ごとのRはスケッチ画面の「角R」で変えられます。")
                    }
                }
            }
            .navigationTitle("フィレット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") { apply() }.disabled(targetID == nil)
                }
            }
            .onAppear {
                targetID = store.selectedID ?? store.features.last?.id
                load()
            }
            .onChange(of: targetID) { _ in load() }
        }
    }

    private func load() {
        guard let f = store.feature(targetID) else { return }
        startR = f.startFillet
        endR = f.endFillet
        cornerR = f.sketch.shapes.flatMap { $0.cornerRadii }.max() ?? 0
    }

    private func apply() {
        guard var f = store.feature(targetID) else { return }
        f.startFillet = max(0, startR)
        f.endFillet = max(0, endR)
        if applyCorners {
            for i in f.sketch.shapes.indices { f.sketch.shapes[i].setAllRadii(max(0, cornerR)) }
        }
        store.upsert(f)
        dismiss()
    }
}
