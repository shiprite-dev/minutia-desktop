import AppKit
import SwiftUI

private final class NotesWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    override func performClose(_ sender: Any?) { orderOut(nil) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            orderOut(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class NotepadPanel {
    private var panel: NSPanel?
    private let makeContent: () -> NSView

    init(content: @escaping () -> NSView) { makeContent = content }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }

    func show(focus: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.alphaValue = 1
        if focus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel?.orderOut(nil) }

    func fadeOut() {
        guard let panel, panel.isVisible else { return }
        if reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NotesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Meeting notes"
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.minSize = NSSize(width: 240, height: 200)
        panel.contentView = makeContent()
        if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - 320 - 16, y: area.maxY - 16))
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static let frameName = "MinutiaNotepad"
}
