import SwiftUI

/// 左のフィーチャーツリー(基準平面・原点・フィーチャーの履歴・ロールバックバー)
struct FeatureTree: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore
    @State private var renaming: Feature?
    @State private var newName = ""

    var body: some View {
        List {
            Label(store.partName, systemImage: "cube")
                .font(.headline)

            ForEach(RefPlane.allCases) { p in
                row(selected: editor.selection == .refPlane(p)) {
                    Label(p.label, systemImage: "square.dashed")
                } onTap: {
                    editor.selection = editor.selection == .refPlane(p) ? nil : .refPlane(p)
                }
                .contextMenu {
                    Button("スケッチ") {
                        editor.selection = .refPlane(p)
                        editor.sketchButton()
                    }
                    Button("垂直表示") { editor.show(.normal(p.plane)) }
                }
            }
            Label("原点", systemImage: "scope").foregroundStyle(.secondary)

            ForEach(Array(store.features.enumerated()), id: \.element.id) { index, f in
                if store.rollbackIndex == index { rollbackBar }
                featureRow(f, index: index)
            }
            if store.rollbackIndex == nil { rollbackBar }
        }
        .listStyle(.sidebar)
        .alert("名前の変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $newName)
            Button("OK") {
                if let f = renaming, !newName.isEmpty { store.rename(f.id, to: newName) }
                renaming = nil
            }
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
    }

    private var rollbackBar: some View {
        HStack {
            Rectangle().fill(Color.blue).frame(height: 3)
            if store.rollbackIndex != nil {
                Button("最後へ") { store.rollback(before: nil) }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func featureRow(_ f: Feature, index: Int) -> some View {
        let rolled = store.isRolledBack(f.id)
        let selected = editor.selection == .feature(f.id)
        Group {
            if f.kind == .extrude || f.kind == .cut {
                DisclosureGroup(isExpanded: Binding(
                    get: { editor.expanded.contains(f.id) },
                    set: { if $0 { editor.expanded.insert(f.id) } else { editor.expanded.remove(f.id) } })
                ) {
                    row(selected: false) {
                        Label(f.sketchName.isEmpty ? "スケッチ" : f.sketchName, systemImage: FeatureKind.sketch.symbol)
                            .font(.callout)
                    } onTap: {
                        editor.selection = .feature(f.id)
                    }
                    .contextMenu {
                        Button("スケッチ編集") { editor.editSketch(f.id) }
                    }
                } label: {
                    featureLabel(f, selected: selected)
                }
            } else {
                featureLabel(f, selected: selected)
            }
        }
        .opacity(rolled || f.suppressed ? 0.45 : 1)
        .contextMenu {
            if f.kind != .sketch {
                Button("フィーチャー編集") { editor.editFeature(f.id) }
            }
            if f.hasSketch {
                Button("スケッチ編集") { editor.editSketch(f.id) }
            }
            if f.kind == .sketch {
                Button("押し出し") {
                    editor.selection = .feature(f.id)
                    editor.featureButton(.extrude)
                }
                Button("押し出しカット") {
                    editor.selection = .feature(f.id)
                    editor.featureButton(.cut)
                }
            }
            Button("名前の変更") {
                newName = f.name
                renaming = f
            }
            Button(f.suppressed ? "抑制解除" : "抑制") { store.toggleSuppressed(f.id) }
            Button("ここまでロールバック") { store.rollback(before: f.id) }
            if f.hasSketch {
                Button("垂直表示") { editor.show(.normal(f.sketch.plane)) }
            }
            Button("削除", role: .destructive) {
                if editor.selection == .feature(f.id) { editor.selection = nil }
                store.delete(f.id)
            }
        }
    }

    private func featureLabel(_ f: Feature, selected: Bool) -> some View {
        row(selected: selected) {
            HStack(spacing: 8) {
                Image(systemName: f.kind.symbol)
                    .foregroundStyle(iconColor(f.kind))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).strikethrough(f.suppressed)
                    Text(f.summary).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if f.kind != .sketch {
                    Button {
                        editor.editFeature(f.id)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } onTap: {
            editor.selection = selected ? nil : .feature(f.id)
        }
    }

    private func iconColor(_ k: FeatureKind) -> Color {
        switch k {
        case .sketch: return .gray
        case .extrude: return .blue
        case .cut: return .pink
        case .fillet: return .orange
        case .chamfer: return .purple
        }
    }

    private func row<Content: View>(selected: Bool, @ViewBuilder content: () -> Content,
                                    onTap: @escaping () -> Void) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .listRowBackground(selected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
