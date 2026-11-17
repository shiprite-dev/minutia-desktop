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
    private(set) var content: MeetingPromptContent?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(content: MeetingPromptContent, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        teardown()
        self.content = content

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
                .announcement: "\(content.title). \(content.primaryTitle) available.",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    func dismiss() {
        content = nil
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

/// The capsule content: the brand mark, the headline, a prominent primary action, and a quiet
/// secondary. The primary label and the secondary shape come from the content, so the same shell
/// renders both the start ("Start taking notes" + xmark dismiss) and end ("Wrap up my notes" +
/// "Keep recording") variants. Glass on macOS 26 and later, a thick material below.
struct MeetingPromptView: View {
    let content: MeetingPromptContent
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.x3) {
            MarkView(barHeight: 18, rises: true)
                .foregroundStyle(Color(nsColor: .labelColor))

            Text(content.title)
                .font(Typo.bodyStrong)
                .foregroundStyle(Color(nsColor: .labelColor))
                .fixedSize()

            Button(action: onStart) {
                Text(content.primaryTitle).padding(.horizontal, Space.x3)
            }
            .buttonStyle(PrimaryButtonStyle())
            .fixedSize()

            if let secondaryTitle = content.secondaryTitle {
                Button(secondaryTitle, action: onDismiss)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel(secondaryTitle)
            } else {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, Space.x3)
        .modifier(CapsuleSurface())
        .fixedSize()
    }
}

private struct CapsuleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.thickMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }
}
