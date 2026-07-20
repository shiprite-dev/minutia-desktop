import AppKit
import QuartzCore
import SwiftUI

/// Thin NSPanel shell for the proactive meeting prompt. Every show/dismiss/expiry/suppression
/// decision lives in `MeetingPrompt` and `AppController`; this only presents them. A nonactivating,
/// floating panel that never takes key focus from the meeting app, joins all Spaces, and floats over
/// fullscreen apps so the prompt is reachable from a fullscreen Zoom/Meet call. It slides in centered
/// just under the menu bar and honors Reduce Motion.
@MainActor
final class MeetingPromptPanel {
    private var panel: NSPanel?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(content: MeetingPromptContent, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        teardown()

        let hosting = NSHostingView(
            rootView: MeetingPromptView(content: content, onStart: onStart, onDismiss: onDismiss))
        hosting.setFrameSize(hosting.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        // Suppress AppKit's implicit window animation so it cannot double with the custom fade/slide.
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        self.panel = panel

        // orderFrontRegardless shows the panel without activating Minutia, so focus stays with the
        // meeting app.
        if reduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            let target = panel.frame
            panel.setFrameOrigin(NSPoint(x: target.origin.x, y: target.origin.y + 8))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }

        // The panel never takes focus, so VoiceOver would not announce it; post an explicit
        // announcement so its arrival and action are heard.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(content.title). Start taking notes available.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        if reduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
    }

    /// Immediate, non-animated teardown, used before showing a fresh panel so a re-show never races
    /// an in-flight fade-out.
    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Center horizontally on the main screen, just under the menu bar.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12))
    }
}

/// The capsule content: a glyph, the headline, a prominent "Start taking notes" action, and a quiet
/// dismiss. System materials and SF Pro defaults; both actions carry VoiceOver labels.
private struct MeetingPromptView: View {
    let content: MeetingPromptContent
    let onStart: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .accessibilityHidden(true)

            Text(content.title)
                .font(.callout.weight(.medium))
                .fixedSize()

            Button(action: onStart) {
                Text("Start taking notes")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .fixedSize()
    }
}
