import Foundation

enum FeatureKind: String, Codable {
    case sketch, extrude, cut, fillet, chamfer, revolve, revolveCut, shell

    /// スケッチを使わず、ほかのフィーチャーの形を変えるもの(フィレット・面取り・シェル)
    var isModifier: Bool { isEdgeFeature || self == .shell }

    /// 回転(中心線を軸にスケッチを回す)
    var isRevolve: Bool { self == .revolve || self == .revolveCut }
    /// 形を足すフィーチャー
    var isAdditive: Bool { self == .extrude || self == .revolve }
    /// 形を削るフィーチャー
    var isSubtractive: Bool { self == .cut || self == .revolveCut }
    /// 押し出し・カット・回転(スケッチから形をつくるもの)
    var isSolidFeature: Bool { isAdditive || isSubtractive }

    /// エッジを選んで使うフィーチャー(フィレット・面取り)
    var isEdgeFeature: Bool { self == .fillet || self == .chamfer }

    var label: String {
        switch self {
        case .sketch: return "スケッチ"
        case .extrude: return "押し出し"
        case .cut: return "押し出しカット"
        case .fillet: return "フィレット"
        case .chamfer: return "面取り"
        case .revolve: return "回転"
        case .revolveCut: return "回転カット"
        case .shell: return "シェル"
        }
    }

    var symbol: String {
        switch self {
        case .sketch: return "pencil.and.outline"
        case .extrude: return "square.stack.3d.up.fill"
        case .cut: return "square.stack.3d.down.dottedline"
        case .fillet: return "app.connected.to.app.below.fill"
        case .chamfer: return "righttriangle"
        case .revolve: return "arrow.triangle.2.circlepath"
        case .revolveCut: return "arrow.triangle.2.circlepath.circle"
        case .shell: return "shippingbox"
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
    /// 端のふちのうち1辺だけ(特徴, 図形, 辺の番号, 先端側なら true)
    case side(UUID, UUID, Int, Bool)

    var featureID: UUID {
        switch self {
        case .start(let id), .end(let id), .corner(let id, _, _), .side(let id, _, _, _): return id
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

    /// 端のエッジを面取り(C)にするか(フィレット・面取り特徴から計算時に入る値)
    var startIsChamfer: Bool?
    var endIsChamfer: Bool?
    /// 1辺だけのフィレット・面取り(計算時に入る値)
    var sideTreatments: [SideTreatment]?

    // フィレット・面取り(面取りでは filletRadius が距離 C)
    var filletRadius: Double = 3
    var filletEdges: [EdgeRef] = []

    var suppressed = false

    /// 回転軸にするスケッチの線(図形と、その辺の番号。中心線は辺0)
    var axisShapeID: UUID?
    var axisSide: Int?

    /// 回転軸の線分(スケッチ座標)。選んでいなければ最初の中心線
    var revolveAxis: (Vec2, Vec2)? {
        if let id = axisShapeID, let shape = sketch.shapes.first(where: { $0.id == id }),
           let seg = shape.segment(axisSide ?? 0) {
            return seg
        }
        if let c = sketch.shapes.first(where: { $0.kind == .centerline && $0.isValid }) {
            return (c.points[0], c.points[1])
        }
        return nil
    }

    /// 元の形とつなげるか(nil は古い保存データ: つなげる)。false なら別のボディになる
    var merge: Bool?
    var mergeResult: Bool {
        get { merge ?? true }
        set { merge = newValue }
    }

    var hasSketch: Bool { !kind.isModifier }

    var summary: String {
        switch kind {
        case .sketch:
            return "\(sketch.plane.name) / 図形 \(sketch.shapes.count)"
        case .extrude, .cut:
            switch endCondition {
            case .throughAll where kind == .cut: return "全貫通"
            case .midPlane: return "中間平面 \(Format.mm(distance)) mm"
            default:
                let sep = kind == .extrude && !mergeResult ? " 別ボディ" : ""
                return "\(Format.mm(distance)) mm\(reversed ? " 反対" : "")\(sep)"
            }
        case .revolve, .revolveCut:
            let sep = kind == .revolve && !mergeResult ? " 別ボディ" : ""
            let mid = endCondition == .midPlane ? " 両側" : (reversed ? " 反対" : "")
            return "\(Format.mm(distance))°\(mid)\(sep)"
        case .fillet:
            return "R\(Format.mm(filletRadius))  エッジ \(filletEdges.count)"
        case .chamfer:
            return "C\(Format.mm(filletRadius))  エッジ \(filletEdges.count)"
        case .shell:
            return "厚み \(Format.mm(filletRadius)) mm  開口 \(filletEdges.count)"
        }
    }
}

/// 端のふちの1辺にかけるフィレット・面取り
struct SideTreatment: Codable, Hashable {
    var shapeID: UUID
    var side: Int
    /// 先端側なら true、スケッチ面側なら false
    var atEnd: Bool
    var size: Double
    var chamfer: Bool
}

/// 保存されるモデル全体
struct ModelData: Codable {
    var partName = "部品1"
    var features: [Feature] = []
    var rollbackIndex: Int?
    /// 保持している断面表示(なければ nil)
    var section: SectionView?
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
