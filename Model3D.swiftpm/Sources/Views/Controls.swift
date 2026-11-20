import SwiftUI

/// ラベル付きの数値入力(mm)。タップするとアプリ内のテンキーが開く
struct NumberField: View {
    var label: String
    @Binding var value: Double
    var unit = "mm"

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            KeypadButton(key: label, title: label, value: $value, width: 96)
            Text(unit).foregroundStyle(.secondary).font(.footnote)
        }
    }
}

struct CompactNumber: View {
    var prefix: String
    var key: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 2) {
            Text(prefix).font(.caption).foregroundStyle(.secondary)
            KeypadButton(key: key, title: key, value: $value, width: nil)
        }
    }
}

/// 数値を表示し、タップでテンキーを開くボタン
struct KeypadButton: View {
    var key: String
    var title: String
    @Binding var value: Double
    var width: CGFloat?
    @EnvironmentObject private var keypad: Keypad

    private var active: Bool { keypad.isOpen && keypad.activeKey == key }

    var body: some View {
        Button {
            let binding = $value
            keypad.open(key: key, title: title, value: value) { binding.wrappedValue = $0 }
        } label: {
            Text(active ? (keypad.buffer.isEmpty ? " " : keypad.buffer) : Format.mm((value * 1000).rounded() / 1000))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: width == nil ? .infinity : width, alignment: .trailing)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(active ? Color.accentColor.opacity(0.12) : Color(uiColor: .systemBackground),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// PropertyManager の見出し(✓ と ✗)
struct PMHeader: View {
    var title: String
    var symbol: String
    var onOK: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Button(action: onOK) {
                Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.green)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
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
                        CompactNumber(prefix: "X", key: "頂点\(i + 1) X", value: Binding(
                            get: { i < shape.points.count ? shape.points[i].x : 0 },
                            set: { if i < shape.points.count { shape.points[i].x = $0 } }))
                        CompactNumber(prefix: "Y", key: "頂点\(i + 1) Y", value: Binding(
                            get: { i < shape.points.count ? shape.points[i].y : 0 },
                            set: { if i < shape.points.count { shape.points[i].y = $0 } }))
                        CompactNumber(prefix: "R", key: "頂点\(i + 1) R", value: Binding(
                            get: { shape.radius(at: i) }, set: { shape.setRadius($0, at: i) }))
                        CompactNumber(prefix: "C", key: "頂点\(i + 1) C", value: Binding(
                            get: { shape.chamfer(at: i) }, set: { shape.setChamfer($0, at: i) }))
                    }
                }
            }
            Button("この図形を削除", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var cornerFields: some View {
        let names = ["左下", "右下", "右上", "左上"]
        ForEach(0..<4, id: \.self) { i in
            HStack {
                Text("\(names[i])の角")
                Spacer()
                CompactNumber(prefix: "R", key: "\(names[i])の角R", value: Binding(
                    get: { shape.radius(at: i) }, set: { shape.setRadius($0, at: i) }))
                    .frame(width: 90)
                CompactNumber(prefix: "C", key: "\(names[i])の角C", value: Binding(
                    get: { shape.chamfer(at: i) }, set: { shape.setChamfer($0, at: i) }))
                    .frame(width: 90)
            }
        }
    }
}

/// コマンドの大きなボタン(アイコンの下に名前)
struct CommandButton: View {
    var title: String
    var symbol: String
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3).frame(height: 24)
                Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(width: 74, height: 54)
            .background(active ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
    }
}
