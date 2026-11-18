import SwiftUI

enum BrandMark {
    static let restRatios: [CGFloat] = [0.44, 0.70, 1.0]
    static let silenceFloor: CGFloat = 0.45
    static let barFullHeight: CGFloat = 340
    private static let barXs: [CGFloat] = [202, 316, 430]
    private static let barWidth: CGFloat = 72
    private static let checkGrid = [CGPoint(x: 552, y: 545), CGPoint(x: 628, y: 650), CGPoint(x: 806, y: 332)]
    private static let barsWindow = CGRect(x: 202, y: 342, width: 300, height: 340)
    private static let checkWindow = CGRect(x: 202, y: 290, width: 646, height: 402)

    static func window(includesCheck: Bool) -> CGRect { includesCheck ? checkWindow : barsWindow }

    static func barHeights(level: Float) -> [CGFloat] { barHeights(levels: [level, level, level]) }

    static func barHeights(levels: [Float]) -> [CGFloat] {
        zip(restRatios, levels).map { rest, level in
            let l = CGFloat(min(1, max(0, level)))
            return rest * (silenceFloor * (1 - l) + l)
        }
    }

    static func frame(barHeight: CGFloat, includesCheck: Bool) -> CGSize {
        let window = window(includesCheck: includesCheck)
        let scale = barHeight / barFullHeight
        return CGSize(width: window.width * scale, height: window.height * scale)
    }

    static func checkPoints(in rect: CGRect) -> [CGPoint] {
        checkGrid.map {
            CGPoint(x: rect.minX + ($0.x - checkWindow.minX) / checkWindow.width * rect.width,
                    y: rect.minY + ($0.y - checkWindow.minY) / checkWindow.height * rect.height)
        }
    }

    static func barRect(index: Int, barHeight: CGFloat, includesCheck: Bool) -> CGRect {
        let window = window(includesCheck: includesCheck)
        let scale = barHeight / barFullHeight
        let height = barFullHeight * restRatios[index] * scale
        return CGRect(x: (barXs[index] - window.minX) * scale, y: (512 - window.minY) * scale - height / 2, width: barWidth * scale, height: height)
    }

    static func checkStroke(barHeight: CGFloat) -> CGFloat { 84 * barHeight / barFullHeight }
}

enum LevelHistory {
    static let depth = 3

    static func push(_ history: [Float], _ level: Float) -> [Float] {
        Array((history + [level]).suffix(depth))
    }

    static func perBar(_ history: [Float], current: Float) -> [Float] {
        let padded = Array(repeating: current, count: max(0, depth - history.count)) + history
        return Array(padded.suffix(depth))
    }

    static func percent(_ level: Float) -> Int { Int((min(1, max(0, level)) * 100).rounded()) }
}

enum CheckReveal {
    static func initialProgress(reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 0 }
    static let delay: TimeInterval = 0.18
    static let drawDuration: TimeInterval = 0.42
    static let popHold: TimeInterval = 0.24
    static var total: TimeInterval { delay + drawDuration + popHold }

    static func progress(elapsed: TimeInterval) -> CGFloat {
        let p = min(1, max(0, (elapsed - delay) / drawDuration))
        return CGFloat(1 - pow(1 - p, 3))
    }

    static func popped(elapsed: TimeInterval) -> Bool {
        elapsed >= delay + drawDuration && elapsed < total
    }
}

private struct PanelVisibleKey: EnvironmentKey { static let defaultValue = true }
private struct ConsentPendingKey: EnvironmentKey { static let defaultValue = false }

private struct ReduceMotionOverrideKey: EnvironmentKey { static let defaultValue: Bool? = nil }
private struct CheckElapsedKey: EnvironmentKey { static let defaultValue: TimeInterval? = nil }
private struct LoopDateKey: EnvironmentKey { static let defaultValue: Date? = nil }
private struct ContrastOverrideKey: EnvironmentKey { static let defaultValue: ColorSchemeContrast? = nil }

extension EnvironmentValues {
    var reduceMotionOverride: Bool? {
        get { self[ReduceMotionOverrideKey.self] }
        set { self[ReduceMotionOverrideKey.self] = newValue }
    }

    var motionReduced: Bool { reduceMotionOverride ?? accessibilityReduceMotion }

    var checkElapsed: TimeInterval? {
        get { self[CheckElapsedKey.self] }
        set { self[CheckElapsedKey.self] = newValue }
    }

    var loopDate: Date? {
        get { self[LoopDateKey.self] }
        set { self[LoopDateKey.self] = newValue }
    }

    var contrastOverride: ColorSchemeContrast? {
        get { self[ContrastOverrideKey.self] }
        set { self[ContrastOverrideKey.self] = newValue }
    }

    var contrastResolved: ColorSchemeContrast { contrastOverride ?? colorSchemeContrast }

    var panelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }

    var consentPending: Bool {
        get { self[ConsentPendingKey.self] }
        set { self[ConsentPendingKey.self] = newValue }
    }
}

enum Loops {
    static func isRunning(visible: Bool, reduceMotion: Bool) -> Bool { visible && !reduceMotion }
}

struct Pulse<Content: View>: View {
    let period: TimeInterval
    var delay: TimeInterval = 0
    @ViewBuilder let content: (Double) -> Content
    @Environment(\.loopDate) private var injected

    static func level(at date: Date, period: TimeInterval, delay: TimeInterval) -> Double {
        let half = period / 2
        let t = (date.timeIntervalSinceReferenceDate - delay).truncatingRemainder(dividingBy: period)
        let phase = (t < 0 ? t + period : t) / half
        let triangle = phase < 1 ? phase : 2 - phase
        return triangle * triangle * (3 - 2 * triangle)
    }

    var body: some View {
        if let injected {
            content(Self.level(at: injected, period: period, delay: delay))
        } else {
            TimelineView(.animation) { context in
                content(Self.level(at: context.date, period: period, delay: delay))
            }
        }
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = BrandMark.checkPoints(in: rect)
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        return path
    }
}

struct LevelBars: View {
    let levels: [Float]
    @Environment(\.motionReduced) private var reduceMotion

    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 3
    static let height: CGFloat = 20

    var body: some View {
        let heights = BrandMark.barHeights(levels: levels)
        HStack(spacing: Self.barGap) {
            ForEach(0..<heights.count, id: \.self) { index in
                Capsule()
                    .fill(Brand.vermilion)
                    .frame(width: Self.barWidth, height: Self.height * heights[index])
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : Motion.meter, value: levels)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(LevelHistory.percent(levels.last ?? 0)) percent")
    }
}

struct MarkView: View {
    var barHeight: CGFloat = 20
    var includesCheck = false
    var checkProgress: CGFloat = 0
    var breathing = false
    var rises = false
    var popped = false
    @Environment(\.motionReduced) private var reduceMotion
    @Environment(\.panelVisible) private var visible

    var body: some View {
        let size = BrandMark.frame(barHeight: barHeight, includesCheck: includesCheck)
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                MarkBar(
                    rect: BrandMark.barRect(index: index, barHeight: barHeight, includesCheck: includesCheck),
                    index: index,
                    breathing: breathing && Loops.isRunning(visible: visible, reduceMotion: reduceMotion),
                    rises: rises && !reduceMotion)
            }
            if includesCheck {
                CheckShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(Brand.vermilion, style: StrokeStyle(lineWidth: BrandMark.checkStroke(barHeight: barHeight), lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(popped ? 1.08 : 1)
        .animation(Motion.pop, value: popped)
        .accessibilityHidden(true)
    }
}

private struct MarkBar: View {
    let rect: CGRect
    let index: Int
    let breathing: Bool
    @State private var risen: Bool

    init(rect: CGRect, index: Int, breathing: Bool, rises: Bool) {
        self.rect = rect
        self.index = index
        self.breathing = breathing
        _risen = State(initialValue: !rises)
    }

    var body: some View {
        let bar = Capsule()
            .fill(.foreground)
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(y: risen ? 1 : 0.2)
            .opacity(risen ? 1 : 0)
        Group {
            if breathing {
                Pulse(period: 1.2, delay: Double(index) * 0.12) { bar.scaleEffect(y: 1 - 0.18 * $0) }
            } else {
                bar
            }
        }
        .position(x: rect.midX, y: rect.midY)
        .task {
            guard !risen else { return }
            try? await Task.sleep(nanoseconds: UInt64(index) * 60_000_000)
            withAnimation(Motion.settle) { risen = true }
        }
    }
}
