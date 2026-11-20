import Foundation

/// アプリのバージョン。変更するたびに1つ上げる(Package.swift の displayVersion / bundleVersion も合わせる)
enum AppVersion {
    static let number = 4
    static var label: String { String(format: "Ver.%02d", number) }
}
