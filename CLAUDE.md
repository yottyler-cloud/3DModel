# このリポジトリでの作業ルール

- 変更をコミットするたびに、アプリのバージョンを1つ上げる
  - `Model3D.swiftpm/Sources/Model/AppVersion.swift` の `number`
  - `Model3D.swiftpm/Package.swift` の `displayVersion` と `bundleVersion`(同じ番号)
  - `CHANGELOG.md` の先頭に「## Ver.NN」と変更内容を日本語で追加
- 変更をプッシュしたら、ユーザーへの返答の最後に、その版のバージョン番号と ZIP のダウンロードリンクを付ける
  - `https://github.com/yottyler-cloud/3dmodel/archive/refs/heads/<ブランチ名>.zip`
- ユーザーへの返答は日本語
