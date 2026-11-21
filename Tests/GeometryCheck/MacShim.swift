import AppKit
import SwiftUI

// チェックを Mac で動かすための置きかえ(iPad 専用の UIColor の代わり)
typealias UIColor = NSColor
extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
}
extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}
