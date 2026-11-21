#!/bin/zsh
# 形の計算のチェックを Mac で実行する(リポジトリのいちばん上のフォルダで: zsh Tests/GeometryCheck/run.sh)
set -e
cd "$(dirname "$0")/../.."
APP=$(ls -d *_Model3D.swiftpm | head -1)
S="$APP/Sources"
mkdir -p .build-check
swiftc -O -o .build-check/geometry-check \
  Tests/GeometryCheck/main.swift Tests/GeometryCheck/MacShim.swift \
  "$S"/Geometry/*.swift "$S/Model/Sketch.swift" "$S/Model/Feature.swift" "$S/Model/Dimensions.swift" \
  "$S/Editor/SketchSession.swift"
.build-check/geometry-check Tests/GeometryCheck/models
