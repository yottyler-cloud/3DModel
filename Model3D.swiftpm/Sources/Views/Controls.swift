import SwiftUI

/// ラベル付きの数値入力(mm)
struct NumberField: View {
    var label: String
    @Binding var value: Double
    var unit = "mm"

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: $value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
            Text(unit).foregroundStyle(.secondary).font(.footnote)
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
                        CompactNumber(prefix: "X", value: Binding(
                            get: { i < shape.points.count ? shape.points[i].x : 0 },
                            set: { if i < shape.points.count { shape.points[i].x = $0 } }))
                        CompactNumber(prefix: "Y", value: Binding(
                            get: { i < shape.points.count ? shape.points[i].y : 0 },
                            set: { if i < shape.points.count { shape.points[i].y = $0 } }))
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
