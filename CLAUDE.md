# このリポジトリでの作業ルール

- 変更をコミットするたびに、アプリのバージョンを1つ上げる
  - アプリのフォルダ名の先頭の番号(`NN_Model3D.swiftpm`)を新しい番号に変える(`git mv`)
  - `NN_Model3D.swiftpm/Sources/Model/AppVersion.swift` の `number`
  - `NN_Model3D.swiftpm/Package.swift` の `displayVersion` と `bundleVersion`(同じ番号)
  - `CHANGELOG.md` の先頭に「## Ver.NN」と変更内容を日本語で追加
  - ダウンロード用の ZIP を作り直す: `Downloads/NN_Model3D.zip`(中身は `NN_Model3D.swiftpm` だけ)。古い版の ZIP は消す
- 変更をプッシュしたら、ユーザーへの返答の最後に、その版のバージョン番号と ZIP の直接ダウンロードリンクを付ける
  - `https://github.com/yottyler-cloud/3dmodel/raw/refs/heads/<ブランチ名>/Downloads/NN_Model3D.zip`
- ユーザーへの返答は日本語
- Mac が使えるときは、変更後に確かめる
  - 形の計算: `zsh Tests/GeometryCheck/run.sh`(Tests/GeometryCheck/models の部品データを計算して、案内が出ないか)
  - アプリのビルド: `NN_Model3D.swiftpm` で `xcodebuild -scheme Model3D -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  - 不具合の出た部品データ(アプリの「データ」で書き出した JSON)は Tests/GeometryCheck/models に入れておく
  - 画面の確認: iPad mini シミュレーターでビルド・起動し `xcrun simctl io <id> screenshot` で撮る(タップはできないので、確認用の起動オプションを使う。例: -demoSection)
  - iPad の Swift Playgrounds は Mac の Xcode より型の推論が弱いことがある。`(条件 ? -1 : 1) * …` のような書き方は避け、数値の型(Double など)を明示する
