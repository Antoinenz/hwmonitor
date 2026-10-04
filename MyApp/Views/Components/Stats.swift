import SwiftUI

/// A short line swatch matching a graph series (solid or dashed).
struct SeriesSwatch: View {
    var color: Color
    var dashed = false

    var body: some View {
        Canvas { gc, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            gc.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
        }
        .frame(width: 12, height: 4)
        .accessibilityHidden(true)
    }
}

/// Status colour for a memory pressure level: none when normal.
func pressureColor(_ level: Int) -> Color? {
    level >= 4 ? .red : level >= 2 ? .orange : nil
}

struct Legend {
    var color: Color
    var dashed = false
}

/// Headline live value: caption above a large figure with a quieter unit.
struct Metric: View {
    var label: String
    var value: String
    /// Disables unit splitting for values like durations.
    var raw = false
    var legend: Legend?
    /// Small qualifier after the value, e.g. "Normal".
    var note: String?
    /// Status colour for the note (e.g. orange for "Warning"); tertiary when nil.
    var noteColor: Color?

    private var parts: (figure: String, unit: String) {
        raw ? (value, "") : Fmt.splitUnit(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let legend { SeriesSwatch(color: legend.color, dashed: legend.dashed) }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(parts.figure)
                    .font(.system(size: 22, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !parts.unit.isEmpty {
                    Text(parts.unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.interpolate)
                }
                if let note {
                    Text(note)
                        .font(.caption.weight(noteColor == nil ? .regular : .medium))
                        .foregroundStyle(noteColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                        .padding(.leading, 2)
                        .contentTransition(.opacity)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            // Digits roll to each new value rather than jumping.
            .animation(.smooth(duration: 0.4), value: value)
            .animation(.smooth(duration: 0.3), value: note)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Row of four headline metrics under the graph. Shares its gutter with
/// `DetailsGrid`, so metric columns 1 and 3 line up with the tables.
struct MetricStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .topLeading), count: 4),
            alignment: .leading,
            spacing: 16
        ) {
            content
        }
    }
}

struct DetailRow {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Titled label/value list for live counters and static hardware info.
struct DetailTable: View {
    var title: String
    var rows: [DetailRow?]

    var body: some View {
        let visible = rows.compactMap { $0 }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(minWidth: 112, alignment: .leading)
                            Text(row.value)
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Two-column area for detail tables, separated from the metrics by a hairline.
struct DetailsGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Divider()
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .topLeading), count: 2),
                alignment: .leading,
                spacing: 24
            ) {
                content
            }
        }
    }
}

/// Slim storage-style usage bar.
struct UsageBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.5), value: fraction)
    }
}

/// Section title used above custom detail blocks.
struct SectionTitle: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// Asks for administrator access when a pane has metrics macOS only exposes to root.
struct ElevationCallout: View {
    @Environment(MetricsStore.self) private var store
    var features: String

    var body: some View {
        switch store.elevation {
        case .on:
            EmptyView()
        case .error(let message):
            callout(icon: "exclamationmark.shield", tint: .orange, text: message, button: "Try Again", disabled: store.isRequestingElevation)
        case .off, .starting:
            let starting = store.elevation == .starting
            callout(
                icon: "lock",
                tint: .secondary,
                text: "\(features) readings require administrator access.",
                button: starting ? "Starting…" : "Grant Access…",
                disabled: starting || store.isRequestingElevation
            )
        }
    }

    private func callout(icon: String, tint: Color, text: String, button: String, disabled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(.medium)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button(button) { store.requestElevation() }
                .controlSize(.small)
                .disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
