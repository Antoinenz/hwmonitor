import SwiftUI

/// The menu bar item: the chosen values drawn into fixed-width cells and
/// rendered as one template image, so the status item never changes width
/// (and never nudges the icons beside it) as numbers change.
struct MenuBarLabel: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.menuBarItems) private var rawItems = MenuBarItem.cpu.rawValue

    var body: some View {
        let items = MenuBarItem.decode(rawItems)
        if items.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
        } else if let image = render(items) {
            Image(nsImage: image)
                .accessibilityLabel(items.map { "\($0.title) \(value(for: $0).joined(separator: " "))" }.joined(separator: ", "))
        }
    }

    private func render(_ items: [MenuBarItem]) -> NSImage? {
        let strip = HStack(spacing: 8) {
            ForEach(items) { item in
                MenuBarCell(item: item, lines: value(for: item))
            }
        }
        .foregroundStyle(.black)
        .frame(height: 22)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    /// Display lines for an item (network shows send and receive on two rows).
    private func value(for item: MenuBarItem) -> [String] {
        let s = store.latest
        switch item {
        case .cpu: return [Fmt.pct(s?.cpu.total)]
        case .gpu: return [Fmt.pct(s?.gpus["0"]?.util)]
        case .memory: return [Fmt.pct(s?.mem.pressure)]
        case .cpuTemperature: return [s?.temps?.cpu.map { "\(Int($0.rounded()))°" } ?? Fmt.dash]
        case .power: return [Fmt.watts(s?.power?.systemW).replacingOccurrences(of: ".00", with: ".0")]
        case .battery: return [s?.battery.map { "\(Int($0.percent))%" } ?? Fmt.dash]
        case .network:
            let send = s?.net.values.reduce(0) { $0 + $1.send }
            let recv = s?.net.values.reduce(0) { $0 + $1.recv }
            return ["↑ \(Fmt.rate(send))", "↓ \(Fmt.rate(recv))"]
        case .disk:
            let read = s?.disks.values.reduce(0) { $0 + $1.read }
            let write = s?.disks.values.reduce(0) { $0 + $1.write }
            return ["R \(Fmt.rate(read))", "W \(Fmt.rate(write))"]
        }
    }
}

/// One fixed-width menu bar cell: a tiny caption over the value, or two
/// stacked rows for throughput items.
private struct MenuBarCell: View {
    var item: MenuBarItem
    var lines: [String]

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    private static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)

    /// The widest text the item can ever show, which fixes the cell width.
    private var template: [String] {
        switch item {
        case .cpu, .gpu, .memory, .battery: ["100%"]
        case .cpuTemperature: ["100°"]
        case .power: ["99.9 W"]
        case .network, .disk: ["↑ 999 KB/s"]
        }
    }

    private var width: CGFloat {
        let font = lines.count > 1 ? Self.rowFont : Self.valueFont
        let widest = template.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let caption = (item.caption as NSString).size(withAttributes: [.font: Self.captionFont]).width
        return ceil(max(widest, lines.count > 1 ? 0 : caption)) + 1
    }

    var body: some View {
        Group {
            if lines.count > 1 {
                VStack(alignment: .trailing, spacing: -2) {
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(Font(Self.rowFont))
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: -1) {
                    Text(item.caption)
                        .font(Font(Self.captionFont))
                        .opacity(0.7)
                    Text(lines.first ?? Fmt.dash)
                        .font(Font(Self.valueFont))
                }
            }
        }
        .lineLimit(1)
        .frame(width: width, alignment: .trailing)
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
