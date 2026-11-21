# このリポジトリでの作業ルール

- 変更をコミットするたびに、アプリのバージョンを1つ上げる
  - アプリのフォルダ名の先頭の番号(`NN_Model3D.swiftpm`)を新しい番号に変える(`git mv`)
  - `NN_Model3D.swiftpm/Sources/Model/AppVersion.swift` の `number`
  - `NN_Model3D.swiftpm/Package.swift` の `displayVersion` と `bundleVersion`(同じ番号)
  - `CHANGELOG.md` の先頭に「## Ver.NN」と変更内容を日本語で追加
- 変更をプッシュしたら、ユーザーへの返答の最後に、その版のバージョン番号と ZIP のダウンロードリンクを付ける
  - `https://github.com/yottyler-cloud/3dmodel/archive/refs/heads/<ブランチ名>.zip`
- ユーザーへの返答は日本語
- Mac が使えるときは、変更後に確かめる
  - 形の計算: `zsh Tests/GeometryCheck/run.sh`(Tests/GeometryCheck/models の部品データを計算して、案内が出ないか)
  - アプリのビルド: `NN_Model3D.swiftpm` で `xcodebuild -scheme Model3D -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  - 不具合の出た部品データ(アプリの「データ」で書き出した JSON)は Tests/GeometryCheck/models に入れておく
