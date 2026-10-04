import SwiftUI

struct OverviewView: View {
    @Environment(MetricsStore.self) private var store
    @Binding var selection: Pane?
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    @AppStorage(PrefKey.memMode) private var memMode: MemoryGraphMode = .pressure

    var body: some View {
        let info = store.info
        let s = store.latest
        let mem = s?.mem
        let temps = s?.temps

        PerfPage(title: "Overview", subtitle: Fmt.join([info.hostName, info.osVersion])) {
            MetricStrip {
                Metric(label: "CPU", value: Fmt.pct(s?.cpu.total))
                Metric(
                    label: "Memory pressure",
                    value: Fmt.pct(mem?.pressure),
                    note: mem.map { Fmt.pressureLabel($0.level) },
                    noteColor: mem.flatMap { pressureColor($0.level) }
                )
                Metric(label: "CPU temperature", value: Fmt.temp(temps?.cpu))
                if let watts = s?.power?.totalW {
                    Metric(label: "Power", value: Fmt.watts(watts))
                } else {
                    Metric(label: "Up time", value: Fmt.uptime(s?.cpu.uptime), raw: true)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 20) {
                OverviewCard(
                    title: "CPU",
                    subtitle: Fmt.join([info.cpu.model, temps?.cpu.map { Fmt.temp($0) }]),
                    value: Fmt.pct(s?.cpu.total),
                    graph: graph(SeriesLibrary.cpu, color: Palette.cpu, max: 100)
                ) { selection = .cpu }

                OverviewCard(
                    title: "Memory",
                    subtitle: mem.map { "\(Fmt.bytes($0.used)) of \(Fmt.bytes($0.total, digits: 0)) in use" } ?? "",
                    value: mem.map { memMode == .pressure ? Fmt.pct($0.pressure) : Fmt.bytes($0.used) } ?? Fmt.dash,
                    graph: graph(
                        SeriesLibrary.memory(memMode),
                        color: Palette.memory,
                        max: memMode == .pressure ? 100 : max(1, mem?.total ?? info.memory.total)
                    )
                ) { selection = .memory }

                ForEach(info.gpus) { gpu in
                    OverviewCard(
                        title: "GPU \(gpu.id)",
                        subtitle: Fmt.join([gpu.name, temps?.gpu.map { Fmt.temp($0) }]),
                        value: Fmt.pct(s?.gpus[gpu.id]?.util),
                        graph: graph(SeriesLibrary.gpu(gpu.id), color: Palette.gpu, max: 100)
                    ) { selection = .gpu(gpu.id) }
                }

                ForEach(info.disks) { disk in
                    OverviewCard(
                        title: disk.title,
                        subtitle: Fmt.join([
                            "\(disk.type) active time",
                            disk.hasNANDSensor ? temps?.nand.map { Fmt.temp($0) } : nil,
                        ]),
                        value: Fmt.pct(s?.disks[disk.id]?.active),
                        graph: graph(SeriesLibrary.diskActive(disk.id), color: Palette.disk, max: 100)
                    ) { selection = .disk(disk.id) }
                }

                ForEach(info.networks) { net in
                    let n = s?.net[net.id]
                    OverviewCard(
                        title: net.title,
                        subtitle: n.map { "↑ \(Fmt.bits($0.send))  ↓ \(Fmt.bits($0.recv))" } ?? "",
                        value: n.map { Fmt.bits($0.send + $0.recv) } ?? Fmt.dash,
                        graph: graph(
                            SeriesLibrary.network(net.id),
                            color: Palette.network,
                            max: SeriesLibrary.networkMax(store.history, id: net.id, window: range.seconds)
                        )
                    ) { selection = .network(net.id) }
                }
            }
        }
    }

    private func graph(_ series: [GraphSeries], color: Color, max: Double) -> TimeGraph {
        TimeGraph(
            samples: store.history,
            series: series,
            color: color,
            window: range.seconds,
            maxValue: max,
            rows: 0,
            columns: 0,
            framed: false
        )
    }
}

/// Clickable summary card; the graph bleeds to the card's sides and bottom.
private struct OverviewCard: View {
    var title: String
    var subtitle: String
    var value: String
    var graph: TimeGraph
    var action: () -> Void

    var body: some View {
        let parts = Fmt.splitUnit(value)
        Button(action: action) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle.isEmpty ? Fmt.dash : subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(parts.figure)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        if !parts.unit.isEmpty {
                            Text(parts.unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                    .animation(.smooth(duration: 0.4), value: value)
                }
                .padding([.horizontal, .top], 14)

                graph.frame(height: 64)
            }
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.07 : hovering ? 0.035 : 0))
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.1)) }
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}
