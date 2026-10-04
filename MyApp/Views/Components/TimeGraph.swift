import SwiftUI

extension EnvironmentValues {
    /// Stops graph animation while the hosting window is fully hidden.
    @Entry var graphsPaused = false
}

/// One line in a `TimeGraph`.
struct GraphSeries {
    enum Fill {
        case none, soft, strong

        /// Fill opacity at the bottom and top of the plot.
        var opacity: (bottom: Double, top: Double) {
            switch self {
            case .none: (0, 0)
            case .soft: (0.02, 0.22)
            case .strong: (0.22, 0.4)
            }
        }
    }

    var value: (Sample) -> Double?
    var fill: Fill = .none
    var dashed = false
    /// Colours spread from the bottom to the top of the plot; the line and fill
    /// take the colour of their height. Overrides the graph colour.
    var ramp: [Color]? = nil
    /// Short name shown in the hover inspector when a graph has several series.
    var label: String? = nil
}

/// Live, time-locked graph. Samples are placed by absolute time and the view
/// redraws continuously, so data scrolls in smoothly from the right.
struct TimeGraph: View {
    var samples: [Sample]
    var series: [GraphSeries]
    var color: Color
    var window: TimeInterval
    var maxValue: Double
    /// Horizontal grid divisions (0 = none).
    var rows = 4
    /// Vertical grid divisions across the window (0 = none). They scroll with the data.
    var columns = 6
    /// Draws the neutral rounded frame. Turn off when the graph sits inside a card.
    var framed = true
    var lineWidth: CGFloat = 1.5
    var cornerRadius: CGFloat = 8
    /// Shows a cursor, point markers and a value readout on hover.
    var inspectable = false
    /// Formats values in the hover readout.
    var format: (Double) -> String = { Fmt.pct($0) }

    @Environment(\.graphsPaused) private var paused
    @State private var hover: CGPoint?
    @State private var scale = ScaleAnimator()
    @State private var width: CGFloat = 0

    /// Draw slightly in the past so the newest sample glides in rather than popping.
    private static let displayDelay: TimeInterval = 1.25

    /// Redraw about every quarter-pixel of movement: 30 fps for a wide 1-minute
    /// graph, a few fps for sidebar thumbnails, and rarely for 1-hour windows.
    private var frameInterval: TimeInterval {
        let pixelsPerSecond = max(1, width) / window
        return min(0.5, max(1.0 / 30.0, 0.25 / pixelsPerSecond))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: framed ? cornerRadius : 0, style: .continuous)
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { context in
            Canvas { gc, size in
                let now = context.date.timeIntervalSince1970
                draw(in: &gc, size: size, now: now - Self.displayDelay, max: scale.value(target: maxValue, at: now))
            }
        }
        .background {
            if framed { shape.fill(Color.primary.opacity(0.025)) }
        }
        .clipShape(shape)
        .overlay {
            if framed { shape.strokeBorder(Color.primary.opacity(0.1)) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover { phase in
            guard inspectable else { return }
            switch phase {
            case .active(let location): hover = location
            case .ended: hover = nil
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func draw(in gc: inout GraphicsContext, size: CGSize, now: TimeInterval, max maxValue: Double) {
        let width = size.width, height = size.height
        guard width > 0, height > 0, maxValue > 0 else { return }
        let start = now - window
        let inset = lineWidth / 2
        let x = { (t: TimeInterval) in CGFloat((t - start) / window) * width }
        let y = { (v: Double) in
            height - inset - CGFloat(min(max(v / maxValue, 0), 1)) * (height - 2 * inset)
        }

        drawGrid(in: &gc, size: size, start: start, now: now, x: x)

        // Aggregate into time-aligned buckets when there are more samples than pixels.
        let bucket = window / Double(width) * 2
        let lower = firstIndex(atOrAfter: start - Swift.max(2, bucket * 2))
        let slice = samples[lower...]
        guard !slice.isEmpty else { return }

        for item in series {
            let points = values(for: item, in: slice, bucket: bucket)
            let runs = segments(points, gap: Swift.max(3, bucket * 2.5), x: x, y: y)
            guard !runs.isEmpty else { continue }

            let bottom = CGPoint(x: 0, y: height)
            let top = CGPoint(x: 0, y: 0)
            let colors = item.ramp ?? [color]

            if item.fill != .none {
                let opacity = item.fill.opacity
                let gradient: Gradient
                if colors.count == 1 {
                    gradient = Gradient(colors: [color.opacity(opacity.bottom), color.opacity(opacity.top)])
                } else {
                    let last = Double(colors.count - 1)
                    gradient = Gradient(stops: colors.enumerated().map { i, c in
                        let f = Double(i) / last
                        return Gradient.Stop(color: c.opacity(opacity.bottom + (opacity.top - opacity.bottom) * f), location: f)
                    })
                }
                for run in runs where run.count > 1 {
                    var area = Path()
                    area.move(to: CGPoint(x: run[0].x, y: height))
                    run.forEach { area.addLine(to: $0) }
                    area.addLine(to: CGPoint(x: run[run.count - 1].x, y: height))
                    area.closeSubpath()
                    gc.fill(area, with: .linearGradient(gradient, startPoint: bottom, endPoint: top))
                }
            }

            let lineShading: GraphicsContext.Shading = colors.count > 1
                ? .linearGradient(Gradient(colors: colors), startPoint: bottom, endPoint: top)
                : .color(color)
            // Anchor the dash pattern to absolute time so dashes travel with the data.
            let phase = item.dashed ? (CGFloat(start / window) * width).truncatingRemainder(dividingBy: 7) : 0
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: item.dashed ? [4, 3] : [], dashPhase: phase)
            for run in runs {
                var line = Path()
                line.addLines(run)
                gc.stroke(line, with: lineShading, style: style)
            }
        }

        if inspectable, let hover, hover.x >= 0, hover.x <= width {
            drawInspector(in: &gc, size: size, at: hover, time: start + Double(hover.x / width) * window, x: x, y: y, maxValue: maxValue)
        }
    }

    private func drawInspector(
        in gc: inout GraphicsContext,
        size: CGSize,
        at location: CGPoint,
        time: TimeInterval,
        x: (TimeInterval) -> CGFloat,
        y: (Double) -> CGFloat,
        maxValue: Double
    ) {
        guard let sample = nearestSample(to: time), abs(sample.t - time) < 2 else { return }
        let sx = x(sample.t).rounded() + 0.5

        var rule = Path()
        rule.move(to: CGPoint(x: sx, y: 0))
        rule.addLine(to: CGPoint(x: sx, y: size.height))
        gc.stroke(rule, with: .color(Color.primary.opacity(0.3)), lineWidth: 1)

        var parts: [String] = []
        for item in series {
            guard let v = item.value(sample) else { continue }
            let point = CGPoint(x: sx, y: y(v))
            let dot = Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
            let dotColor = item.ramp.map { ramp in
                ramp[Swift.min(ramp.count - 1, Int(Swift.min(Swift.max(v / maxValue, 0), 0.999) * Double(ramp.count)))]
            } ?? color
            gc.fill(dot, with: .color(dotColor))
            gc.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
            let value = format(v)
            parts.append(item.label.map { "\($0) \(value)" } ?? value)
        }
        guard !parts.isEmpty else { return }

        let clock = Date(timeIntervalSince1970: sample.t).formatted(date: .omitted, time: .standard)
        let text = Text("\(Text(parts.joined(separator: "   ")).font(.callout.weight(.semibold)).monospacedDigit())\n\(Text(clock).font(.caption).foregroundStyle(.secondary).monospacedDigit())")
        let resolved = gc.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 320, height: 100))
        let padding = CGSize(width: 8, height: 5)
        let box = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        // Sit beside the cursor, flipping to the left near the right edge.
        var origin = CGPoint(x: sx + 10, y: 8)
        if origin.x + box.width > size.width - 4 { origin.x = sx - 10 - box.width }
        origin.x = Swift.max(4, origin.x)
        let rect = CGRect(origin: origin, size: box)
        let bubble = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
        gc.fill(bubble, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.94)))
        gc.stroke(bubble, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        gc.draw(resolved, in: rect.insetBy(dx: padding.width, dy: padding.height))
    }

    private func drawGrid(
        in gc: inout GraphicsContext,
        size: CGSize,
        start: TimeInterval,
        now: TimeInterval,
        x: (TimeInterval) -> CGFloat
    ) {
        var grid = Path()
        if rows > 1 {
            for i in 1..<rows {
                let gy = (size.height * CGFloat(i) / CGFloat(rows)).rounded() + 0.5
                grid.move(to: CGPoint(x: 0, y: gy))
                grid.addLine(to: CGPoint(x: size.width, y: gy))
            }
        }
        if columns > 0 {
            let step = window / Double(columns)
            var t = (start / step).rounded(.up) * step
            while t < now {
                let gx = x(t).rounded() + 0.5
                grid.move(to: CGPoint(x: gx, y: 0))
                grid.addLine(to: CGPoint(x: gx, y: size.height))
                t += step
            }
        }
        gc.stroke(grid, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)
    }

    private func firstIndex(atOrAfter t: TimeInterval) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].t < t { low = mid + 1 } else { high = mid }
        }
        return Swift.max(0, low - 1)
    }

    private func nearestSample(to t: TimeInterval) -> Sample? {
        guard !samples.isEmpty else { return nil }
        let i = firstIndex(atOrAfter: t)
        let candidates = [samples[safe: i], samples[safe: i + 1]].compactMap { $0 }
        return candidates.min { abs($0.t - t) < abs($1.t - t) }
    }

    private func values(for item: GraphSeries, in slice: ArraySlice<Sample>, bucket: Double) -> [(t: TimeInterval, v: Double?)] {
        guard bucket > 1.5 else { return slice.map { ($0.t, item.value($0)) } }
        var result: [(t: TimeInterval, v: Double?)] = []
        var key = Double.nan
        var sum = 0.0
        var count = 0
        func flush() {
            guard !key.isNaN else { return }
            result.append(((key + 0.5) * bucket, count > 0 ? sum / Double(count) : nil))
        }
        for sample in slice {
            let k = (sample.t / bucket).rounded(.down)
            if k != key {
                flush()
                key = k
                sum = 0
                count = 0
            }
            if let v = item.value(sample) {
                sum += v
                count += 1
            }
        }
        flush()
        return result
    }

    /// Splits points into continuous runs, breaking on missing values or time gaps (e.g. sleep).
    private func segments(
        _ points: [(t: TimeInterval, v: Double?)],
        gap: TimeInterval,
        x: (TimeInterval) -> CGFloat,
        y: (Double) -> CGFloat
    ) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        var lastT: TimeInterval?
        for point in points {
            guard let v = point.v else {
                if !current.isEmpty { runs.append(current) }
                current = []
                lastT = nil
                continue
            }
            if let lastT, point.t - lastT > gap, !current.isEmpty {
                runs.append(current)
                current = []
            }
            current.append(CGPoint(x: x(point.t), y: y(v)))
            lastT = point.t
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

/// Eases the vertical scale toward a new maximum instead of snapping, so
/// auto-scaled graphs (network, disk, GPU memory) rescale smoothly.
private final class ScaleAnimator {
    private var from = 0.0
    private var to = 0.0
    private var start = 0.0
    private let duration = 0.5

    func value(target: Double, at now: TimeInterval) -> Double {
        if to == 0 {
            from = target
            to = target
            start = now
        } else if target != to {
            from = current(at: now)
            to = target
            start = now
        }
        return current(at: now)
    }

    private func current(at now: TimeInterval) -> Double {
        let p = min(1, max(0, (now - start) / duration))
        let eased = 1 - pow(1 - p, 3)
        return from + (to - from) * eased
    }
}

/// Titled graph with Task Manager-style scale and axis labels.
struct GraphPanel<Content: View>: View {
    var title: String
    var scale: String?
    var axis: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                if let scale {
                    Text(scale)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.35), value: scale)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            content

            if let axis {
                HStack {
                    Text(axis)
                    Spacer()
                    Text(verbatim: "0")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }
}

nonisolated enum GraphMath {
    /// A "nice" axis maximum covering the largest value in the visible window.
    static func autoMax(
        _ samples: [Sample],
        window: TimeInterval,
        floor: Double,
        bytes: Bool = false,
        _ values: (Sample) -> [Double]
    ) -> Double {
        let start = Date().timeIntervalSince1970 - window - 2
        var peak = 0.0
        for sample in samples.reversed() {
            if sample.t < start { break }
            for v in values(sample) { peak = max(peak, v) }
        }
        return bytes ? Fmt.niceCeilBytes(max(peak, floor)) : Fmt.niceCeil(max(peak, floor))
    }

    /// Largest value in the visible window, or nil when there's no data.
    static func peak(_ samples: [Sample], window: TimeInterval, _ value: (Sample) -> Double?) -> Double? {
        let start = Date().timeIntervalSince1970 - window - 2
        var peak: Double?
        for sample in samples.reversed() {
            if sample.t < start { break }
            if let v = value(sample) { peak = max(peak ?? v, v) }
        }
        return peak
    }
}

extension View {
    /// Main graph height: grows with the window and leaves room for the details below.
    func flexibleGraphHeight(reserve: CGFloat = 420, min minHeight: CGFloat = 180, max maxHeight: CGFloat = 520) -> some View {
        containerRelativeFrame(.vertical) { length, _ in
            Swift.min(maxHeight, Swift.max(minHeight, length - reserve))
        }
    }
}

/// Reports whether the hosting window is at least partly visible on screen.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}
