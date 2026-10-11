// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An sRGB colour with 0–255 channels, as written in Design/tokens.json.
public struct ALRGBA: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Converts RGB channels from the 0–255 scale to fractions and keeps alpha on the 0–1 scale.
    /// Values are stored without clamping or validation.
    public init(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Double = 1) {
        self.red = Double(red) / 255
        self.green = Double(green) / 255
        self.blue = Double(blue) / 255
        self.alpha = alpha
    }
}

extension Color {
    /// A colour that follows the system appearance: `light` in light mode, `dark` in dark mode.
    public init(light: ALRGBA, dark: ALRGBA) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
        #else
        self.init(.sRGB, red: light.red, green: light.green, blue: light.blue, opacity: light.alpha)
        #endif
    }
}
