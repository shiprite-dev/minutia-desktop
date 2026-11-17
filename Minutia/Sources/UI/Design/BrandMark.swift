import SwiftUI

enum BrandMark {
    static let restRatios: [CGFloat] = [0.44, 0.70, 1.0]
    static let silenceFloor: CGFloat = 0.45
    static let gridWindow: CGFloat = 700
    static let gridOrigin: CGFloat = 162
    private static let barXs: [CGFloat] = [202, 316, 430]
    private static let barWidth: CGFloat = 72
    private static let barFullHeight: CGFloat = 340
    private static let checkGrid = [CGPoint(x: 552, y: 545), CGPoint(x: 628, y: 650), CGPoint(x: 806, y: 332)]

    static func barHeights(level: Float) -> [CGFloat] {
        let l = CGFloat(min(1, max(0, level)))
        return restRatios.map { $0 * (silenceFloor * (1 - l) + l) }
    }

    static func checkPoints(in rect: CGRect) -> [CGPoint] {
        checkGrid.map {
            CGPoint(x: rect.minX + ($0.x - gridOrigin) / gridWindow * rect.width,
                    y: rect.minY + ($0.y - gridOrigin) / gridWindow * rect.height)
        }
    }

    static func barRect(index: Int, in side: CGFloat) -> CGRect {
        let scale = side / gridWindow
        let height = barFullHeight * restRatios[index] * scale
        let centerY = (512 - gridOrigin) * scale
        return CGRect(x: (barXs[index] - gridOrigin) * scale, y: centerY - height / 2, width: barWidth * scale, height: height)
    }
}

enum CheckReveal {
    static func initialProgress(reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 0 }
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
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 3
    static let height: CGFloat = 20

    var body: some View {
        let heights = BrandMark.barHeights(level: level)
        HStack(spacing: Self.barGap) {
            ForEach(0..<heights.count, id: \.self) { index in
                Capsule()
                    .fill(Brand.vermilion)
                    .frame(width: Self.barWidth, height: Self.height * heights[index])
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : Motion.meter, value: level)
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(RecordingView.litBars(level: level, total: RecordingView.barCount)) of \(RecordingView.barCount)")
    }
}

struct MarkView: View {
    var side: CGFloat = 36
    var checkProgress: CGFloat = 0
    var breathing = false
    var rises = false
    var popped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                MarkBar(rect: BrandMark.barRect(index: index, in: side), index: index, breathing: breathing && !reduceMotion, rises: rises && !reduceMotion)
            }
            CheckShape()
                .trim(from: 0, to: checkProgress)
                .stroke(Brand.vermilion, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: side, height: side)
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
            .fill(.primary)
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(y: risen ? 1 : 0.2)
            .opacity(risen ? 1 : 0)
        Group {
            if breathing {
                bar.phaseAnimator([1.0, 0.82]) { view, scale in
                    view.scaleEffect(y: scale)
                } animation: { _ in
                    .easeInOut(duration: 0.6).delay(Double(index) * 0.12)
                }
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
