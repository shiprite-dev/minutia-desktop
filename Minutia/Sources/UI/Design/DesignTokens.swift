import AppKit
import SwiftUI

struct Token: ShapeStyle {
    let light: UInt32
    let dark: UInt32

    func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }

    func resolve(in environment: EnvironmentValues) -> Color {
        let value = hex(dark: environment.colorScheme == .dark)
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

enum Contrast {
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

enum Brand {
    static let vermilion = Token(light: 0xE23A00, dark: 0xE23A00)
    static let vermilionFill = Token(light: 0xD43500, dark: 0xD43500)
    static let vermilionText = Token(light: 0xB92D00, dark: 0xFF7452)
    static let accentSoft = Token(light: 0xFFE4DB, dark: 0x4A2A22)
    static let ink2 = Token(light: 0x5F5A55, dark: 0xA8A39E)
    static let ink3 = Token(light: 0x706B66, dark: 0x98938E)
    static let warn = Token(light: 0x8D6000, dark: 0xD4A62A)
    static let warnSoft = Token(light: 0xFFF1CC, dark: 0x3F3420)
}

enum Typo {
    private static let opsz: Int = 0x6F70737A
    private static let wght: Int = 0x77676874

    static let frauncesAvailable: Bool = frauncesFont(size: 17) != nil

    private static func frauncesFont(size: CGFloat) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Fraunces",
            kCTFontVariationAttribute as NSFontDescriptor.AttributeName: [opsz: min(144, max(9, size)), wght: 450],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == "Fraunces" else { return nil }
        return font
    }

    static func display(_ size: CGFloat) -> Font {
        guard let font = frauncesFont(size: size) else { return .system(size: size, design: .serif) }
        return Font(font)
    }

    static let title = display(17)
    static let masthead = display(22)
    static let timer = Font.system(size: 34, weight: .light).monospacedDigit()
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let eyebrow = Font.system(size: 10, weight: .medium, design: .monospaced)
}

enum Space {
    static let x1: CGFloat = 4, x2: CGFloat = 8, x3: CGFloat = 12, x4: CGFloat = 16, x6: CGFloat = 24
    static let panelWidth: CGFloat = 320
}

enum Radius {
    static let control: CGFloat = 8, notice: CGFloat = 10, bar: CGFloat = 2
}

enum Motion {
    static let snap = Animation.snappy(duration: 0.22)
    static let settle = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let pop = Animation.spring(response: 0.32, dampingFraction: 0.62)
    static let meter = Animation.easeOut(duration: 0.12)
    static let fade = Animation.easeOut(duration: 0.15)
    static func resolved(_ animation: Animation, reduce: Bool) -> Animation { reduce ? fade : animation }
}
