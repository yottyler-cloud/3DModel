import SwiftUI

/// アプリ内のテンキー(ソフトウェアキーボードが出ない環境でも数値を入れられるように)
final class Keypad: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var activeKey: String?
    @Published private(set) var title = ""
    @Published private(set) var buffer = ""
    @Published private(set) var error = ""

    private var replaceNext = true
    private var live = true
    private var apply: ((Double) -> Void)?
    private var onClose: (() -> Void)?

    /// テンキーを開く。live = true なら、正しい数値になるたびにすぐ反映する
    func open(key: String, title: String, value: Double, live: Bool = true,
              apply: @escaping (Double) -> Void, onClose: (() -> Void)? = nil) {
        if isOpen && activeKey != key { finish(commit: false) }
        self.activeKey = key
        self.title = title
        self.buffer = Format.mm(value)
        self.live = live
        self.apply = apply
        self.onClose = onClose
        replaceNext = true
        error = ""
        isOpen = true
    }

    func close() {
        finish(commit: false)
    }

    private func finish(commit: Bool) {
        if commit, let v = MathExpression.evaluate(buffer) { apply?(v) }
        let done = onClose
        isOpen = false
        activeKey = nil
        apply = nil
        onClose = nil
        error = ""
        done?()
    }

    var resultText: String {
        if !error.isEmpty { return error }
        guard let v = MathExpression.evaluate(buffer) else { return buffer.isEmpty ? "数値・式を入力" : "式を入力中" }
        return "＝ " + Format.mm((v * 1000).rounded() / 1000)
    }

    func press(_ key: String) {
        guard isOpen else { return }
        error = ""
        switch key {
        case "C":
            buffer = ""
            replaceNext = false
        case "⌫":
            buffer = replaceNext ? "" : String(buffer.dropLast())
            replaceNext = false
        case "±":
            buffer = buffer.isEmpty ? "-" : (buffer.hasPrefix("-(") && buffer.hasSuffix(")")
                ? String(buffer.dropFirst(2).dropLast()) : "-(\(buffer))")
            replaceNext = false
        case "=":
            if let v = MathExpression.evaluate(buffer) {
                buffer = Format.mm((v * 1000).rounded() / 1000)
                replaceNext = true
            } else {
                error = "式を確認してください"
            }
            return
        case "完了":
            if MathExpression.evaluate(buffer) == nil {
                error = "式を確認してください"
                return
            }
            finish(commit: true)
            return
        default:
            let token = key == "×" ? "*" : key == "÷" ? "/" : key == "−" ? "-" : key
            let isOp = ["+", "-", "*", "/"].contains(token)
            buffer = (replaceNext && !isOp ? "" : buffer) + token
            replaceNext = false
        }
        if live, let v = MathExpression.evaluate(buffer) { apply?(v) }
    }
}

/// 四則演算と括弧の式を計算する
enum MathExpression {
    static func evaluate(_ text: String) -> Double? {
        let t = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
            .filter { !$0.isWhitespace }
        guard !t.isEmpty, t.count <= 200 else { return nil }
        var p = Parser(chars: Array(t))
        guard let v = p.expression(), p.index == p.chars.count, v.isFinite, abs(v) <= 1_000_000 else { return nil }
        return v
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0
        var peek: Character? { index < chars.count ? chars[index] : nil }

        mutating func take(_ c: Character) -> Bool {
            guard peek == c else { return false }
            index += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                index += 1
                guard let right = term() else { return nil }
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = unary() else { return nil }
            while let op = peek, op == "*" || op == "/" {
                index += 1
                guard let right = unary() else { return nil }
                if op == "/" {
                    guard right != 0 else { return nil }
                    left /= right
                } else {
                    left *= right
                }
            }
            return left
        }

        mutating func unary() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 32 else { return nil }
            if take("+") { return unary() }
            if take("-") { return unary().map { -$0 } }
            if take("(") {
                guard let v = expression(), take(")") else { return nil }
                return v
            }
            return number()
        }

        mutating func number() -> Double? {
            let start = index
            while let c = peek, c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }
}

/// テンキーの表示
struct KeypadView: View {
    @ObservedObject var keypad: Keypad
    private let rows = [["C", "(", ")", "⌫"], ["7", "8", "9", "÷"], ["4", "5", "6", "×"],
                        ["1", "2", "3", "−"], ["±", "0", ".", "+"]]

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(keypad.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button {
                    keypad.close()
                } label: {
                    Image(systemName: "chevron.down.circle").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(keypad.buffer.isEmpty ? " " : keypad.buffer)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Spacer()
                Text(keypad.resultText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(keypad.error.isEmpty ? Color.accentColor : Color.red)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 5) {
                    ForEach(rows[r], id: \.self) { key($0, strong: false) }
                }
            }
            HStack(spacing: 5) {
                key("=", strong: false)
                key("完了", strong: true)
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func key(_ k: String, strong: Bool) -> some View {
        Button {
            keypad.press(k)
        } label: {
            Text(k)
                .font(.system(size: k == "完了" ? 15 : 18, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .frame(height: 33)
                .foregroundStyle(strong ? Color.white : Color.primary)
                .background(strong ? Color.accentColor : Color(uiColor: .systemBackground),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(k == "⌫" ? "1文字削除" : k == "C" ? "全消去" : k)
    }
}
