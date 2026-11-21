# このリポジトリでの作業ルール

- 変更をコミットするたびに、アプリのバージョンを1つ上げる
  - アプリのフォルダ名の先頭の番号(`NN_Model3D.swiftpm`)を新しい番号に変える(`git mv`)
  - `NN_Model3D.swiftpm/Sources/Model/AppVersion.swift` の `number`
  - `NN_Model3D.swiftpm/Package.swift` の `displayVersion` と `bundleVersion`(同じ番号)
  - `CHANGELOG.md` の先頭に「## Ver.NN」と変更内容を日本語で追加
- 変更をプッシュしたら、ユーザーへの返答の最後に、その版のバージョン番号と ZIP のダウンロードリンクを付ける
  - `https://github.com/yottyler-cloud/3dmodel/archive/refs/heads/<ブランチ名>.zip`
- ユーザーへの返答は日本語
