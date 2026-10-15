import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

/// Brand tokens, mirroring devrobotics.dev assets/css/tokens.css (light + dark).
enum Theme {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        return Color(hex: light)
        #endif
    }

    static let accent = dyn(0x0369a1, 0x7dd3fc)
    static let accentStrong = dyn(0x075985, 0xbae6fd)
    static let accentContrast = dyn(0xffffff, 0x0a0b0d)
    static let background = dyn(0xfafaf9, 0x0a0b0d)
    static let surface = dyn(0xffffff, 0x131518)
    static let surface2 = dyn(0xf4f4f5, 0x1a1d21)
    static let border = dyn(0xe4e4e7, 0x24272c)
    static let text = dyn(0x111113, 0xededed)
    static let muted = dyn(0x5b606a, 0x8a8f98)
    static let ok = dyn(0x15803d, 0x4ade80)
    static let warn = dyn(0xb45309, 0xfbbf24)
    /// Errors and destructive states. Use instead of `.red`.
    static let danger = dyn(0xb91c1c, 0xf87171)

    // MARK: Fonts

    private static let fontFiles = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold",
                                    "JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-Bold"]

    /// Call once at launch. Failures just fall back to system fonts.
    static func registerFonts() {
        for name in fontFiles {
            let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Brand font. `mono: true` gives JetBrains Mono, otherwise Inter. Scales with Dynamic Type.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let family = mono ? "JetBrainsMono" : "Inter"
        let suffix: String
        switch weight {
        case .bold, .heavy, .black: suffix = "Bold"
        case .semibold: suffix = mono ? "Bold" : "SemiBold"
        case .medium: suffix = "Medium"
        default: suffix = "Regular"
        }
        let name = "\(family)-\(suffix)"
        #if canImport(UIKit)
        guard UIFont(name: name, size: size) != nil else {
            return .system(size: size, weight: weight, design: mono ? .monospaced : .default)
        }
        #endif
        return .custom(name, size: size, relativeTo: style)
    }
}

#if canImport(UIKit)
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
#else
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}
#endif
