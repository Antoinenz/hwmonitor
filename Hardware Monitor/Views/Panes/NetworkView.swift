import SwiftUI

struct NetworkView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    var networkID: String

    var body: some View {
        if let net = store.info.networks.first(where: { $0.id == networkID }) {
            content(net)
        } else if !store.isReady {
            Color.clear
        } else {
            DeviceGoneView(title: "This connection is no longer active", systemImage: "network.slash")
        }
    }

    private func content(_ net: NetworkInfo) -> some View {
        let id = networkID
        let n = store.latest?.net[id]
        let max = SeriesLibrary.networkMax(store.history, id: id, window: range.seconds)

        return PerfPage(title: net.title, subtitle: "\(net.kind.label) · \(net.id)") {
            GraphPanel(title: "Throughput", scale: Fmt.bits(max), axis: range.axisLabel) {
                TimeGraph(
                    samples: store.history,
                    series: [
                        GraphSeries(value: { $0.net[id]?.recv }, fill: .soft, label: "↓"),
                        GraphSeries(value: { $0.net[id]?.send }, dashed: true, label: "↑"),
                    ],
                    color: Palette.network,
                    window: range.seconds,
                    maxValue: max,
                    columns: range.gridColumns,
                    inspectable: true,
                    format: { Fmt.bits($0) }
                )
                .flexibleGraphHeight()
            }
            .contextMenu { GraphMenuContent { EmptyView() } }

            MetricStrip {
                Metric(label: "Receive", value: Fmt.bits(n?.recv), legend: Legend(color: Palette.network))
                Metric(label: "Send", value: Fmt.bits(n?.send), legend: Legend(color: Palette.network, dashed: true))
                Metric(label: "Peak receive", value: Fmt.bits(GraphMath.peak(store.history, window: range.seconds) { $0.net[id]?.recv }))
                Metric(label: "Peak send", value: Fmt.bits(GraphMath.peak(store.history, window: range.seconds) { $0.net[id]?.send }))
            }

            DetailsGrid {
                DetailTable(title: "Adapter", rows: [
                    DetailRow("Name", net.name),
                    DetailRow("Interface", net.id),
                    DetailRow("Connection type", net.kind.label),
                    net.mac.map { DetailRow("MAC address", $0) },
                ])
                DetailTable(title: "Addresses", rows: addressRows(net))
            }
        }
    }

    private func addressRows(_ net: NetworkInfo) -> [DetailRow?] {
        var rows = [DetailRow("IPv4", net.ipv4.isEmpty ? Fmt.dash : net.ipv4.joined(separator: ", "))]
        let ipv6 = net.ipv6.isEmpty ? [Fmt.dash] : Array(net.ipv6.prefix(3))
        for (i, address) in ipv6.enumerated() {
            rows.append(DetailRow(i == 0 ? "IPv6" : "", address))
        }
        return rows
    }
}
