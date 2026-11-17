import AppKit
import SwiftUI
import XCTest
@testable import Minutia

@MainActor
final class GalleryShotsTests: XCTestCase {
    func test_everyStateRendersInLightAndDark() throws {
        guard let raw = FileManager.default.contents(atPath: "/tmp/minutia-shots-dir"),
              let directory = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for entry in StateGallery.entries {
            for dark in [false, true] {
                let backdrop = dark ? Color(red: 0.145, green: 0.145, blue: 0.15) : Color(red: 0.96, green: 0.96, blue: 0.96)
                let hosting = NSHostingView(rootView: entry.view.background(backdrop).environment(\.colorScheme, dark ? .dark : .light))
                hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = hosting.appearance
                window.backgroundColor = dark ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
                window.contentView = hosting
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                hosting.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(entry.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
