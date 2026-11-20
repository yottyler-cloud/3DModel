import SwiftUI

/// 画面上部のコマンド(タブで「フィーチャー」と「スケッチ」を切りかえ)
struct CommandBar: View {
    @EnvironmentObject var editor: Editor
    @EnvironmentObject var store: ModelStore
    @State private var confirmNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    if editor.tab == .features { featureCommands } else { sketchCommands }
                }
                Divider().frame(height: 44)
                documentCommands
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            HStack(spacing: 0) {
                ForEach(CommandTab.allCases) { t in
                    Button {
                        editor.tab = t
                    } label: {
                        Text(t.label)
                            .font(.footnote.weight(editor.tab == t ? .bold : .regular))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .background(editor.tab == t ? Color(uiColor: .systemBackground) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .confirmationDialog("新しい部品にしますか?(元に戻すで戻せます)", isPresented: $confirmNew) {
            Button("新しい部品", role: .destructive) {
                editor.cancelAll()
                editor.selection = nil
                store.newPart()
            }
        }
    }

    private var featureCommands: some View {
        HStack(spacing: 2) {
            CommandButton(title: "押し出し", symbol: FeatureKind.extrude.symbol,
                          active: editor.session?.draft.kind == .extrude || editor.awaiting == .feature(.extrude)) {
                editor.featureButton(.extrude)
            }
            CommandButton(title: "押し出し\nカット", symbol: FeatureKind.cut.symbol,
                          active: editor.session?.draft.kind == .cut || editor.awaiting == .feature(.cut)) {
                editor.featureButton(.cut)
            }
            CommandButton(title: "フィレット", symbol: FeatureKind.fillet.symbol,
                          active: editor.session?.draft.kind == .fillet) {
                editor.filletButton()
            }
            Divider().frame(height: 44).padding(.horizontal, 4)
            CommandButton(title: editor.sketch == nil ? "スケッチ" : "スケッチ終了",
                          symbol: editor.sketch == nil ? "pencil.and.outline" : "rectangle.portrait.and.arrow.right",
                          active: editor.sketch != nil) {
                editor.sketchButton()
            }
        }
    }

    private var sketchCommands: some View {
        HStack(spacing: 2) {
            CommandButton(title: editor.sketch == nil ? "スケッチ" : "スケッチ終了",
                          symbol: editor.sketch == nil ? "pencil.and.outline" : "rectangle.portrait.and.arrow.right",
                          active: editor.sketch != nil) {
                editor.sketchButton()
            }
            Divider().frame(height: 44).padding(.horizontal, 4)
            ForEach(SketchTool.allCases) { t in
                CommandButton(title: t.label, symbol: t.symbol,
                              active: editor.sketch?.tool == t || editor.awaiting == .sketch(t)) {
                    editor.chooseTool(t)
                }
            }
        }
    }

    private var documentCommands: some View {
        HStack(spacing: 2) {
            if editor.sketch != nil {
                CommandButton(title: "戻す", symbol: "arrow.uturn.backward") { editor.sketch?.undo() }
            } else {
                CommandButton(title: "元に戻す", symbol: "arrow.uturn.backward") { store.undo() }
                    .disabled(!store.canUndo || editor.session != nil)
                CommandButton(title: "やり直し", symbol: "arrow.uturn.forward") { store.redo() }
                    .disabled(!store.canRedo || editor.session != nil)
            }
            if let url = editor.exportURL, editor.sketch == nil {
                ShareLink(item: url) {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.up").font(.title3).frame(height: 24)
                        Text("STL").font(.caption2)
                    }
                    .frame(width: 60, height: 54)
                }
                .foregroundStyle(Color.primary)
            }
            CommandButton(title: "新規", symbol: "doc.badge.plus") { confirmNew = true }
                .disabled(editor.sketch != nil || editor.session != nil)
        }
    }
}
