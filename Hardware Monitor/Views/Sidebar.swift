import SwiftUI

nonisolated enum Pane: Hashable {
    case overview
    case cpu
    case memory
    case power
    case disk(String)
    case network(String)
    case gpu(String)

    /// String form for remembering the selection across launches.
    var storageKey: String {
        switch self {
        case .overview: "overview"
        case .cpu: "cpu"
        case .memory: "memory"
        case .power: "power"
        case .disk(let id): "disk:\(id)"
        case .network(let id): "network:\(id)"
        case .gpu(let id): "gpu:\(id)"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count == 2 ? parts[1] : nil) {
        case ("overview", nil): self = .overview
        case ("cpu", nil): self = .cpu
        case ("memory", nil): self = .memory
        case ("power", nil): self = .power
        case ("disk", let id?): self = .disk(id)
        case ("network", let id?): self = .network(id)
        case ("gpu", let id?): self = .gpu(id)
        default: return nil
        }
    }
}

/// Series definitions shared by the sidebar, overview cards and detail panes.
enum SeriesLibrary {
    static let cpu = [GraphSeries(value: { $0.cpu.total }, fill: .soft)]

    static func memory(_ mode: MemoryGraphMode) -> [GraphSeries] {
        switch mode {
        case .pressure: [GraphSeries(value: { $0.mem.pressure }, fill: .soft, ramp: Palette.pressureRamp)]
        case .usage: [GraphSeries(value: { $0.mem.used }, fill: .soft)]
        }
    }

    static func diskActive(_ id: String) -> [GraphSeries] {
        [GraphSeries(value: { $0.disks[id]?.active }, fill: .soft)]
    }

    static func network(_ id: String) -> [GraphSeries] {
        [
            GraphSeries(value: { $0.net[id]?.recv }, fill: .soft),
            GraphSeries(value: { $0.net[id]?.send }, dashed: true),
        ]
    }

    static func networkMax(_ samples: [Sample], id: String, window: TimeInterval) -> Double {
        // Minimum axis: 100 Kbps (12.5 KB/s).
        GraphMath.autoMax(samples, window: window, floor: 12_500) { s in
            [s.net[id]?.send ?? 0, s.net[id]?.recv ?? 0]
        }
    }

    static func gpu(_ id: String) -> [GraphSeries] {
        [GraphSeries(value: { $0.gpus[id]?.util }, fill: .soft)]
    }
}

struct PerfSidebar: View {
    @Environment(MetricsStore.self) private var store
    @Binding var selection: Pane?
    /// Double-clicking a row opens that pane in compact mode.
    var onDoubleClick: (Pane) -> Void = { _ in }
    @AppStorage(PrefKey.memMode) private var memMode: MemoryGraphMode = .pressure

    private static let thumbWindow: TimeInterval = 60

    var body: some View {
        let s = store.latest
        let info = store.info

        List(selection: $selection) {
            SidebarRow(title: "Overview", subtitle: info.hostName) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1))
                    }
                    .overlay {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                    }
            }
            .tag(Pane.overview)
            .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.overview) })

            Section("System") {
                SidebarRow(
                    title: "CPU",
                    subtitle: Fmt.join([
                        s.map { Fmt.pct($0.cpu.total) },
                        s?.cpu.speedMHz.map { Fmt.mhz($0) },
                        s?.temps?.cpu.map { Fmt.temp($0) },
                    ])
                ) {
                    thumb(SeriesLibrary.cpu, color: Palette.cpu, max: 100)
                }
                .tag(Pane.cpu)
                .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.cpu) })

                SidebarRow(title: "Memory", subtitle: memorySummary(s?.mem)) {
                    thumb(
                        SeriesLibrary.memory(memMode),
                        color: Palette.memory,
                        max: memMode == .usage ? max(1, s?.mem.total ?? info.memory.total) : 100
                    )
                }
                .tag(Pane.memory)
                .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.memory) })

                ForEach(info.gpus) { gpu in
                    SidebarRow(
                        title: "GPU \(gpu.id)",
                        subtitle: Fmt.join([
                            gpu.name,
                            s?.gpus[gpu.id].map { Fmt.pct($0.util) },
                            s?.temps?.gpu.map { Fmt.temp($0) },
                        ])
                    ) {
                        thumb(SeriesLibrary.gpu(gpu.id), color: Palette.gpu, max: 100)
                    }
                    .tag(Pane.gpu(gpu.id))
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.gpu(gpu.id)) })
                }

                SidebarRow(title: "Power", subtitle: powerSummary(s)) {
                    thumb(
                        [GraphSeries(value: { $0.power?.systemW }, fill: .soft)],
                        color: Palette.power,
                        max: GraphMath.autoMax(store.history, window: Self.thumbWindow, floor: 10) { [$0.power?.systemW ?? 0] }
                    )
                }
                .tag(Pane.power)
                .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.power) })
            }

            if !info.disks.isEmpty {
                Section("Storage") {
                    ForEach(info.disks) { disk in
                        SidebarRow(
                            title: disk.title,
                            subtitle: Fmt.join([
                                disk.type,
                                s?.disks[disk.id].map { Fmt.pct($0.active) },
                                disk.hasNANDSensor ? s?.temps?.nand.map { Fmt.temp($0) } : nil,
                            ])
                        ) {
                            thumb(SeriesLibrary.diskActive(disk.id), color: Palette.disk, max: 100)
                        }
                        .tag(Pane.disk(disk.id))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.disk(disk.id)) })
                    }
                }
            }

            if !info.networks.isEmpty {
                Section("Network") {
                    ForEach(info.networks) { net in
                        SidebarRow(
                            title: net.title,
                            subtitle: s?.net[net.id].map { "↑ \(Fmt.bits($0.send))  ↓ \(Fmt.bits($0.recv))" } ?? ""
                        ) {
                            thumb(
                                SeriesLibrary.network(net.id),
                                color: Palette.network,
                                max: SeriesLibrary.networkMax(store.history, id: net.id, window: Self.thumbWindow)
                            )
                        }
                        .tag(Pane.network(net.id))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick(Pane.network(net.id)) })
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
    }

    private func thumb(_ series: [GraphSeries], color: Color, max: Double) -> TimeGraph {
        TimeGraph(
            samples: store.history,
            series: series,
            color: color,
            window: Self.thumbWindow,
            maxValue: max,
            rows: 0,
            columns: 0,
            lineWidth: 1.25,
            cornerRadius: 6,
            adaptsToSelection: true
        )
    }

    private func powerSummary(_ s: Sample?) -> String {
        Fmt.join([
            s?.power?.systemW.map { Fmt.watts($0) },
            s?.battery.map { "\(Int($0.percent))%\($0.isCharging ? " ⚡︎" : "")" },
        ])
    }

    private func memorySummary(_ mem: MemorySample?) -> String {
        guard let mem, mem.total > 0 else { return "" }
        let gb = { (b: Double) in String(format: "%.1f", b / 1_073_741_824) }
        return "\(gb(mem.used))/\(gb(mem.total)) GB (\(Fmt.pct(mem.used / mem.total * 100)))"
    }
}

/// Sidebar row: live mini graph, title and a single-line summary.
private struct SidebarRow<Thumb: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var thumb: Thumb

    var body: some View {
        HStack(spacing: 10) {
            thumb
                .frame(width: 48, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? Fmt.dash : subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
