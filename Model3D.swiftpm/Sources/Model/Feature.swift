import Foundation

enum FeatureKind: String, Codable {
    case sketch, extrude, cut, fillet

    var label: String {
        switch self {
        case .sketch: return "スケッチ"
        case .extrude: return "押し出し"
        case .cut: return "押し出しカット"
        case .fillet: return "フィレット"
        }
    }

    var symbol: String {
        switch self {
        case .sketch: return "pencil.and.outline"
        case .extrude: return "square.stack.3d.up.fill"
        case .cut: return "square.stack.3d.down.dottedline"
        case .fillet: return "app.connected.to.app.below.fill"
        }
    }
}

/// 押し出しの終わり方
enum EndCondition: String, Codable, CaseIterable, Identifiable {
    case blind, throughAll, midPlane
    var id: String { rawValue }

    var label: String {
        switch self {
        case .blind: return "ブラインド(距離指定)"
        case .throughAll: return "全貫通"
        case .midPlane: return "中間平面(両側)"
        }
    }
}

/// フィレットで選んだエッジ。どの特徴の、どの部分のエッジかで覚える
enum EdgeRef: Codable, Hashable {
    /// スケッチ面側のふち
    case start(UUID)
    /// 先端側のふち(カットなら底のすみ)
    case end(UUID)
    /// 図形の角から伸びるエッジ(特徴, 図形, 角の番号)
    case corner(UUID, UUID, Int)

    var featureID: UUID {
        switch self {
        case .start(let id), .end(let id), .corner(let id, _, _): return id
        }
    }
}

/// フィーチャーツリーの1行
struct Feature: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: FeatureKind
    var sketch = Sketch()
    /// 押し出し・カットに使ったスケッチの名前
    var sketchName = ""

    // 押し出し・カット
    var distance: Double = 10
    var endCondition: EndCondition = .blind
    var reversed = false
    var useStartOffset = false
    var startOffset: Double = 0
    /// フィレット特徴から計算時に入る値(直接は編集しない)
    var startFillet: Double = 0
    var endFillet: Double = 0

    // フィレット
    var filletRadius: Double = 3
    var filletEdges: [EdgeRef] = []

    var suppressed = false

    var hasSketch: Bool { kind != .fillet }

    var summary: String {
        switch kind {
        case .sketch:
            return "\(sketch.plane.name) / 図形 \(sketch.shapes.count)"
        case .extrude, .cut:
            switch endCondition {
            case .throughAll where kind == .cut: return "全貫通"
            case .midPlane: return "中間平面 \(Format.mm(distance)) mm"
            default: return "\(Format.mm(distance)) mm\(reversed ? " 反対" : "")"
            }
        case .fillet:
            return "R\(Format.mm(filletRadius))  エッジ \(filletEdges.count)"
        }
    }
}

/// 保存されるモデル全体
struct ModelData: Codable {
    var partName = "部品1"
    var features: [Feature] = []
    var rollbackIndex: Int?
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
