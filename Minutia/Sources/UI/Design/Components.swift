import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motionReduced) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.bodyStrong)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Brand.vermilionFill, in: RoundedRectangle(cornerRadius: Radius.control))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(Motion.resolved(Motion.snap, reduce: reduceMotion), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.x3)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(.primary.opacity(configuration.isPressed ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Hairline.style(contrast), lineWidth: Hairline.width(contrast)))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.body)
            .foregroundStyle(contrast == .increased ? AnyShapeStyle(Brand.ink2) : AnyShapeStyle(Brand.ink3))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

enum Hairline {
    static func width(_ contrast: ColorSchemeContrast) -> CGFloat { contrast == .increased ? 1 : 0.5 }
    static func noticeBorder(_ contrast: ColorSchemeContrast) -> CGFloat { contrast == .increased ? 1 : 0 }
    static func quietTextIsStrong(_ contrast: ColorSchemeContrast) -> Bool { contrast == .increased }
    static func style(_ contrast: ColorSchemeContrast) -> AnyShapeStyle {
        contrast == .increased ? AnyShapeStyle(Brand.ink3) : AnyShapeStyle(.quaternary)
    }
}

struct HairlineRule: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(Hairline.style(contrast))
            .frame(height: Hairline.width(contrast))
    }
}

struct Eyebrow: View {
    let text: String
    var live = false
    @Environment(\.motionReduced) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.panelVisible) private var visible

    var body: some View {
        HStack(spacing: Space.x2 - 2) {
            if live {
                let dot = Circle().fill(Brand.vermilion).frame(width: 6, height: 6)
                if Loops.isRunning(visible: visible, reduceMotion: reduceMotion) {
                    dot.phaseAnimator([1.0, 0.45]) { view, opacity in
                        view.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 1)
                    }
                } else {
                    dot
                }
            }
            Text(text.uppercased())
                .font(Typo.eyebrow)
                .tracking(1.4)
                .foregroundStyle(live ? AnyShapeStyle(Brand.vermilionText) : Hairline.quietTextIsStrong(contrast) ? AnyShapeStyle(Brand.ink2) : AnyShapeStyle(Brand.ink3))
        }
    }
}

enum NoticeKind { case accent, warn, neutral }

struct NoticeRow<Icon: View, Content: View>: View {
    let kind: NoticeKind
    @ViewBuilder let icon: Icon
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .top, spacing: Space.x2) {
            icon.frame(width: 20, height: 17)
            content
                .font(Typo.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.notice))
        .overlay {
            if Hairline.noticeBorder(contrast) > 0 {
                RoundedRectangle(cornerRadius: Radius.notice).strokeBorder(Brand.ink3, lineWidth: Hairline.noticeBorder(contrast))
            }
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .accent: AnyShapeStyle(Brand.accentSoft)
        case .warn: AnyShapeStyle(Brand.warnSoft)
        case .neutral: AnyShapeStyle(.primary.opacity(0.06))
        }
    }
}

struct ProgressHairline: View {
    let fraction: Double
    @Environment(\.motionReduced) private var reduceMotion

    var body: some View {
        let clamped = min(1, max(0, fraction))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Brand.vermilion).frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 2)
        .animation(Motion.resolved(Motion.settle, reduce: reduceMotion), value: clamped)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}
