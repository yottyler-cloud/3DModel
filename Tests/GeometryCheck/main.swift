import Foundation

// 形の計算のチェック(Mac で実行)。
// models フォルダの部品データ(アプリの「データ」で書き出した JSON)を読み込み、
// iPad のアプリと同じコードで、フィーチャーを1つずつ足しながら形を計算する。
// 案内(計算できなかった等)が出たら失敗として終了コード 1 を返す。

func f3(_ v: Double) -> String { String(format: "%.3f", v) }

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/GeometryCheck/models"
let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    .filter { $0.hasSuffix(".json") }.sorted()
var failed = false

for file in files {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
    guard let data = try? Data(contentsOf: url),
          let model = try? JSONDecoder().decode(ModelData.self, from: data) else {
        print("✗ \(file): 読み込めません")
        failed = true
        continue
    }
    print("■ \(file)")
    let all = model.features
    for n in 1...max(all.count, 1) where n <= all.count {
        let r = SolidBuilder.build(Array(all.prefix(n)))
        let b = r.mesh.bounds.size
        let ok = r.messages.isEmpty
        if !ok { failed = true }
        print("  \(ok ? "✓" : "✗") \(n): \(all[n - 1].name)  \(f3(b.x))×\(f3(b.y))×\(f3(b.z))  三角形\(r.mesh.triangleCount)")
        for m in r.messages { print("      \(m)") }
    }
}
print(failed ? "失敗あり" : "すべて成功")
exit(failed ? 1 : 0)
