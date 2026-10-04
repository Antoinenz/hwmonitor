import SwiftUI

struct MemoryView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    @AppStorage(PrefKey.memMode) private var mode: MemoryGraphMode = .pressure

    var body: some View {
        let info = store.info
        let mem = store.latest?.mem
        let total = mem?.total ?? info.memory.total
        let pressure = mode == .pressure

        PerfPage(
            title: "Memory",
            subtitle: Fmt.join([Fmt.bytes(total, digits: 0), info.memory.type])
        ) {
            options
        } content: {
            VStack(alignment: .leading, spacing: 20) {
                GraphPanel(
                    title: pressure ? "Memory pressure" : "Memory used",
                    scale: pressure ? "100%" : Fmt.bytes(total),
                    axis: range.axisLabel
                ) {
                    TimeGraph(
                        samples: store.history,
                        series: SeriesLibrary.memory(mode),
                        color: Palette.memory,
                        window: range.seconds,
                        maxValue: pressure ? 100 : max(1, total),
                        columns: range.gridColumns,
                        inspectable: true,
                        format: pressure ? { Fmt.pct($0) } : { Fmt.bytes($0) }
                    )
                    .flexibleGraphHeight(reserve: 470)
                }
                MemoryComposition(mem: mem)
            }
            .contextMenu { GraphMenuContent { options } }

            MetricStrip {
                Metric(
                    label: "Pressure",
                    value: Fmt.pct(mem?.pressure),
                    note: mem.map { Fmt.pressureLabel($0.level) },
                    noteColor: mem.flatMap { pressureColor($0.level) }
                )
                Metric(label: "In use", value: mem.map { Fmt.bytes($0.used) } ?? Fmt.dash)
                Metric(label: "Available", value: mem.map { Fmt.bytes($0.free + $0.cached) } ?? Fmt.dash)
                Metric(label: "Swap used", value: mem.map { Fmt.bytes($0.swapUsed) } ?? Fmt.dash)
            }

            DetailsGrid {
                DetailTable(title: "Usage", rows: [
                    DetailRow("App memory", mem.map { Fmt.bytes($0.app) } ?? Fmt.dash),
                    DetailRow("Wired memory", mem.map { Fmt.bytes($0.wired) } ?? Fmt.dash),
                    DetailRow("Compressed", mem.map { Fmt.bytes($0.compressed) } ?? Fmt.dash),
                    DetailRow("Cached files", mem.map { Fmt.bytes($0.cached) } ?? Fmt.dash),
                    DetailRow("Swap", mem.map { "\(Fmt.bytes($0.swapUsed)) of \(Fmt.bytes($0.swapTotal))" } ?? Fmt.dash),
                ])
                DetailTable(title: "Hardware", rows: [
                    DetailRow("Total", Fmt.bytes(total)),
                    info.memory.type.map { DetailRow("Type", $0) },
                    info.memory.manufacturer.map { DetailRow("Manufacturer", $0) },
                ])
            }

            TopProcesses(sort: .memory)
        }
    }

    @ViewBuilder private var options: some View {
        Picker("Change Graph To", selection: $mode) {
            ForEach(MemoryGraphMode.allCases) { mode in
                Text(mode.menuLabel).tag(mode)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Stacked bar showing how physical memory is split up.
private struct MemoryComposition: View {
    var mem: MemorySample?

    private struct Segment: Identifiable {
        var id: String { label }
        var label: String
        var bytes: Double
        var color: Color
    }

    private var segments: [Segment] {
        [
            Segment(label: "App memory", bytes: mem?.app ?? 0, color: Palette.memory),
            Segment(label: "Wired", bytes: mem?.wired ?? 0, color: Palette.memory.opacity(0.6)),
            Segment(label: "Compressed", bytes: mem?.compressed ?? 0, color: Palette.memory.opacity(0.35)),
            Segment(label: "Cached files", bytes: mem?.cached ?? 0, color: Color.primary.opacity(0.2)),
        ]
    }

    var body: some View {
        let total = max(1, mem?.total ?? 1)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Memory composition", trailing: mem.map { "\(Fmt.bytes($0.free)) free" })

            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, geometry.size.width * segment.bytes / total - 1))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Color.primary.opacity(0.1))
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.7), value: mem?.used)

            HStack(spacing: 20) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle().fill(segment.color).frame(width: 8, height: 8)
                        Text(segment.label).foregroundStyle(.secondary)
                        Text(mem == nil ? Fmt.dash : Fmt.bytes(segment.bytes)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
