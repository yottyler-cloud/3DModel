import Foundation

enum FeatureKind: String, Codable {
    case extrude, cut

    var label: String {
        switch self {
        case .extrude: return "押し出し"
        case .cut: return "引き抜き"
        }
    }

    var symbol: String {
        switch self {
        case .extrude: return "square.stack.3d.up.fill"
        case .cut: return "square.stack.3d.down.dottedline"
        }
    }
}

enum ExtentDirection: String, Codable, CaseIterable, Identifiable {
    case normal, reverse, symmetric
    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "法線方向"
        case .reverse: return "反対方向"
        case .symmetric: return "両側対称"
        }
    }
}

/// 形状をつくる1手順(履歴の1行)
struct Feature: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: FeatureKind
    var sketch = Sketch()
    /// 押し出し・引き抜きの距離(mm)
    var distance: Double = 10
    var direction: ExtentDirection = .normal
    /// 引き抜きを全体に貫通させる
    var throughAll = false
    /// スケッチ面側のエッジのフィレット半径
    var startFillet: Double = 0
    /// 先端側のエッジのフィレット半径
    var endFillet: Double = 0
    /// 一時的に無効にする
    var suppressed = false

    var summary: String {
        var s = "\(kind.label) "
        s += throughAll && kind == .cut ? "貫通" : "\(Format.mm(distance))"
        if startFillet > 0 || endFillet > 0 {
            s += "  R\(Format.mm(startFillet))/R\(Format.mm(endFillet))"
        }
        return s
    }
}

/// モデル全体(保存されるもの)
struct ModelData: Codable {
    var features: [Feature] = []
}

enum Format {
    static func mm(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 { return String(Int(v.rounded())) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
