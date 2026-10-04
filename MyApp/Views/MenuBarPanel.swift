import SwiftUI

/// Live CPU percentage shown in the menu bar.
struct MenuBarLabel: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        let cpu = store.latest.map { Int($0.cpu.total.rounded()) }
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(cpu.map { "\($0)%" } ?? Fmt.dash)
                .monospacedDigit()
        }
        .accessibilityLabel("CPU \(cpu.map { "\($0) percent" } ?? "unknown")")
    }
}

/// Compact panel from the menu bar: mini graphs for the main subsystems and a
/// shortcut back to the full window.
struct MenuBarPanel: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.memMode) private var memMode: MemoryGraphMode = .pressure
    @State private var visible = true

    private static let window: TimeInterval = 60

    var body: some View {
        let s = store.latest
        let info = store.info
        let primaryNetwork = info.networks.first { $0.kind != .vpn } ?? info.networks.first

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.hostName).font(.headline).lineLimit(1)
                Spacer()
                Text("Up \(Fmt.uptime(s?.cpu.uptime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 10) {
                PanelRow(
                    title: "CPU",
                    detail: Fmt.join([s?.temps?.cpu.map { Fmt.temp($0) }, s?.cpu.speedMHz.map { Fmt.mhz($0) }]),
                    value: Fmt.pct(s?.cpu.total),
                    graph: graph(SeriesLibrary.cpu, color: Palette.cpu, max: 100)
                )
                PanelRow(
                    title: "Memory",
                    detail: s.map { "\(Fmt.bytes($0.mem.used)) used · \(Fmt.pressureLabel($0.mem.level))" } ?? "",
                    value: s.map { memMode == .pressure ? Fmt.pct($0.mem.pressure) : Fmt.bytes($0.mem.used) } ?? Fmt.dash,
                    graph: graph(
                        SeriesLibrary.memory(memMode),
                        color: Palette.memory,
                        max: memMode == .pressure ? 100 : max(1, info.memory.total)
                    )
                )
                ForEach(info.gpus) { gpu in
                    PanelRow(
                        title: info.gpus.count > 1 ? "GPU \(gpu.id)" : "GPU",
                        detail: s?.temps?.gpu.map { Fmt.temp($0) } ?? "",
                        value: Fmt.pct(s?.gpus[gpu.id]?.util),
                        graph: graph(SeriesLibrary.gpu(gpu.id), color: Palette.gpu, max: 100)
                    )
                }
                if let net = primaryNetwork {
                    let n = s?.net[net.id]
                    PanelRow(
                        title: net.title,
                        detail: n.map { "↑ \(Fmt.bits($0.send))" } ?? "",
                        value: n.map { "↓ \(Fmt.bits($0.recv))" } ?? Fmt.dash,
                        graph: graph(
                            SeriesLibrary.network(net.id),
                            color: Palette.network,
                            max: SeriesLibrary.networkMax(store.history, id: net.id, window: Self.window)
                        )
                    )
                }
            }

            Divider()

            HStack {
                Button("Open Hardware Monitor") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut("o")
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Hardware Monitor")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
        .environment(\.graphsPaused, !visible)
        .environment(\.frozenAt, store.frozenAt)
        .background(WindowVisibilityReader(isVisible: $visible))
    }

    private func graph(_ series: [GraphSeries], color: Color, max: Double) -> TimeGraph {
        TimeGraph(
            samples: store.history,
            series: series,
            color: color,
            window: Self.window,
            maxValue: max,
            rows: 0,
            columns: 0,
            lineWidth: 1.25,
            cornerRadius: 6
        )
    }
}

private struct PanelRow: View {
    var title: String
    var detail: String
    var value: String
    var graph: TimeGraph

    var body: some View {
        HStack(spacing: 10) {
            graph.frame(width: 64, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(detail.isEmpty ? Fmt.dash : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.4), value: value)
        }
    }
}
