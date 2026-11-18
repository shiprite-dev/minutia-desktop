import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Minutia

struct FillRegion {
    let frame: CGRect
    let area: Int
}

@MainActor
enum Host {
    static func view<V: View>(_ root: V, dark: Bool = false) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    static func size<V: View>(_ root: V, dark: Bool = false) -> CGSize {
        view(root, dark: dark).fittingSize
    }

    static func backdrop(dark: Bool) -> Color {
        dark ? Color(red: 0.145, green: 0.145, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.96)
    }

    static func appearance(dark: Bool, highContrast: Bool) -> NSAppearance? {
        switch (dark, highContrast) {
        case (false, false): NSAppearance(named: .aqua)
        case (true, false): NSAppearance(named: .darkAqua)
        case (false, true): NSAppearance(named: .accessibilityHighContrastAqua)
        case (true, true): NSAppearance(named: .accessibilityHighContrastDarkAqua)
        }
    }

    static func render<V: View>(_ root: V, dark: Bool = false, highContrast: Bool = false, spin: TimeInterval = 0.6, scale: Int = 3) -> CGImage? {
        let hosting = NSHostingView(rootView: root.background(backdrop(dark: dark)).environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = appearance(dark: dark, highContrast: highContrast)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        RunLoop.current.run(until: Date().addingTimeInterval(spin))
        hosting.layoutSubtreeIfNeeded()
        return capture(hosting, scale: scale)
    }

    static func capture(_ hosting: NSView, scale: Int = 3) -> CGImage? {
        let size = hosting.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep.cgImage
    }

    static func read(_ image: CGImage) -> Seen {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let found = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
        return Seen(text: found.map(\.0).joined(separator: " "), frames: found)
    }

    static func text<V: View>(_ root: V, dark: Bool = false, scale: Int = 3) -> Seen {
        guard let image = render(root, dark: dark, scale: scale) else { return Seen(text: "", frames: []) }
        return read(image)
    }

    static func pixels(_ image: CGImage) -> (width: Int, height: Int, data: [UInt8]) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, data)
    }

    static func differingBytes(_ a: CGImage, _ b: CGImage) -> Int {
        zip(pixels(a).data, pixels(b).data).filter { $0 != $1 }.count
    }

    private static func isFill(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        abs(Int(r) - 0xD4) < 10 && abs(Int(g) - 0x35) < 10 && Int(b) < 12
    }

    /// Connected areas painted in the primary button fill, in Vision's normalized frame
    /// (origin bottom-left) so they compare directly with OCR text frames. Small specks (icons,
    /// glyph antialiasing) are ignored.
    static func fillRegions(_ image: CGImage, minimumArea: Int = 5000) -> [FillRegion] {
        let (width, height, data) = pixels(image)
        var mask = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            mask[index] = isFill(data[index * 4], data[index * 4 + 1], data[index * 4 + 2])
        }
        var regions: [FillRegion] = []
        for start in 0..<(width * height) where mask[start] {
            var stack = [start], area = 0
            var (minX, maxX, minY, maxY) = (width, 0, height, 0)
            mask[start] = false
            while let current = stack.popLast() {
                let x = current % width, y = current / width
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for next in [current - 1, current + 1, current - width, current + width] where next >= 0 && next < width * height && mask[next] {
                    if (next == current - 1 && x == 0) || (next == current + 1 && x == width - 1) { continue }
                    mask[next] = false
                    stack.append(next)
                }
            }
            guard area >= minimumArea else { continue }
            let frame = CGRect(
                x: Double(minX) / Double(width), y: 1 - Double(maxY + 1) / Double(height),
                width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
            regions.append(FillRegion(frame: frame, area: area))
        }
        return regions
    }

    static func fills<V: View>(_ root: V, dark: Bool = false) -> [FillRegion] {
        render(root, dark: dark, spin: 0.15).map { fillRegions($0) } ?? []
    }

    static func contrast(in image: CGImage, frame: CGRect) -> Double? {
        let (width, height, data) = pixels(image)
        let x0 = max(0, Int(frame.minX * Double(width))), x1 = min(width, Int(frame.maxX * Double(width)) + 1)
        let y0 = max(0, Int((1 - frame.maxY) * Double(height))), y1 = min(height, Int((1 - frame.minY) * Double(height)) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        func hex(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * width + x) * 4
            return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
        }
        var buckets: [UInt32: (count: Int, color: UInt32)] = [:]
        for y in y0..<y1 { for x in x0..<x1 {
            let color = hex(x, y), key = (color >> 3) & 0x1F1F1F
            buckets[key] = (((buckets[key]?.count ?? 0) + 1), buckets[key]?.color ?? color)
        } }
        guard let background = buckets.max(by: { $0.value.count < $1.value.count })?.value.color else { return nil }
        let backgroundLuminance = Contrast.luminance(background)
        var farthest = background, distance = 0.0
        for y in y0..<y1 { for x in x0..<x1 {
            let color = hex(x, y), gap = abs(Contrast.luminance(color) - backgroundLuminance)
            if gap > distance { distance = gap; farthest = color }
        } }
        return Contrast.ratio(farthest, background)
    }

    static func worstContrast(in image: CGImage, seen: Seen) -> (text: String, ratio: Double)? {
        seen.frames.filter { $0.0.contains(where: \.isLetter) }
            .compactMap { text, frame in contrast(in: image, frame: frame).map { (text, $0) } }
            .min { $0.1 < $1.1 }
    }

    static func vermilionRuns(_ image: CGImage) -> (pixels: Int, longestRun: Int) {
        let (width, height, data) = pixels(image)
        var count = 0, longest = 0
        for row in 0..<height {
            var run = 0
            for column in 0..<width {
                let i = (row * width + column) * 4
                if abs(Int(data[i]) - 0xE2) < 14 && abs(Int(data[i + 1]) - 0x3A) < 14 && Int(data[i + 2]) < 20 {
                    count += 1; run += 1; longest = max(longest, run)
                } else { run = 0 }
            }
        }
        return (count, longest)
    }

    static func vermilionPixels<V: View>(_ root: V, spin: TimeInterval) -> Int {
        render(root, spin: spin).map { vermilionRuns($0).pixels } ?? 0
    }
}

struct Seen {
    let text: String
    let frames: [(String, CGRect)]

    private static let homoglyphs: [Character: Character] = [
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0445}": "x", "\u{0443}": "y",
        "\u{043C}": "m", "\u{0442}": "t", "\u{043D}": "h", "\u{043A}": "k", "\u{0432}": "b",
    ]

    private static let negations: Set<String> = ["not", "no", "never", "cannot", "without", "t"]

    private static func tokens(_ value: String) -> [String] {
        let folded = String(value.lowercased().map { homoglyphs[$0] ?? $0 }.map { $0 == "|" || $0 == "i" ? "l" : $0 })
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "rn", with: "m") }
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            haystack[start..<start + needle.count].elementsEqual(needle) && !(start > 0 && negations.contains(haystack[start - 1]))
        }
    }

    func has(_ expected: String) -> Bool { Self.contains(Self.tokens(text), Self.tokens(expected)) }

    func frame(of expected: String) -> CGRect? { frames(of: expected).first }

    func frames(of expected: String) -> [CGRect] {
        let needle = Self.tokens(expected)
        return frames.filter { Self.contains(Self.tokens($0.0), needle) }.map(\.1)
    }
}

final class LoopClockBox: ObservableObject {
    @Published var date: Date?
}

private struct Dated: View {
    @ObservedObject var box: LoopClockBox
    let content: AnyView

    var body: some View { content.environment(\.loopDate, box.date) }
}

@MainActor
final class LivePanel {
    private let box = LoopClockBox()
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init<V: View>(_ root: V) {
        let content = AnyView(root.background(Host.backdrop(dark: false)).environment(\.colorScheme, .light))
        hosting = NSHostingView(rootView: AnyView(Dated(box: box, content: content)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        spin(0.5)
    }

    func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func detach() { window.contentView = NSView() }

    func attach() { window.contentView = hosting }

    func image(atLoopTime seconds: TimeInterval) -> CGImage {
        box.date = Date(timeIntervalSinceReferenceDate: seconds)
        spin(0.3)
        hosting.layoutSubtreeIfNeeded()
        return Host.capture(hosting)!
    }

    func animates() -> Bool {
        Host.differingBytes(image(atLoopTime: 0), image(atLoopTime: 0.45)) > 0
    }
}
