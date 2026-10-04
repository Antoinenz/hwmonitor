import SwiftUI

struct GPUView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    var gpuID: String

    var body: some View {
        if let gpu = store.info.gpus.first(where: { $0.id == gpuID }) {
            content(gpu)
        } else if !store.isReady {
            Color.clear
        } else {
            DeviceGoneView(title: "This GPU is no longer available", systemImage: "cpu")
        }
    }

    private func content(_ gpu: GPUInfo) -> some View {
        let id = gpuID
        let g = store.latest?.gpus[id]
        let power = store.latest?.power
        // IOReport (frequency and power) only describes the integrated Apple GPU.
        let detailed = id == "0" && g?.mhz != nil
        let mhzMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 500) { [$0.gpus[id]?.mhz ?? 0] }
        let wattsMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 1) { [$0.power?.gpuW ?? 0] }
        let memMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 256 * 1_048_576, bytes: true) { s in
            [s.gpus[id]?.memUsed ?? 0]
        }

        return PerfPage(title: "GPU \(gpu.id)", subtitle: gpu.name) {
            VStack(alignment: .leading, spacing: 20) {
                GraphPanel(title: "% Utilization", scale: "100%", axis: range.axisLabel) {
                    TimeGraph(
                        samples: store.history,
                        series: [
                            GraphSeries(value: { $0.gpus[id]?.util }, fill: .soft, label: "Usage"),
                            GraphSeries(value: { $0.gpus[id]?.active }, dashed: true, label: "Active"),
                        ],
                        color: Palette.gpu,
                        window: range.seconds,
                        maxValue: 100,
                        columns: range.gridColumns,
                        inspectable: true
                    )
                    .flexibleGraphHeight(reserve: detailed ? 560 : 440, min: 140, max: 420)
                }

                if detailed {
                    HStack(spacing: 16) {
                        GraphPanel(title: "Frequency", scale: Fmt.mhz(mhzMax)) {
                            TimeGraph(
                                samples: store.history,
                                series: [GraphSeries(value: { $0.gpus[id]?.mhz }, fill: .soft)],
                                color: Palette.gpu,
                                window: range.seconds,
                                maxValue: mhzMax,
                                rows: 2,
                                columns: range.gridColumns,
                                inspectable: true,
                                format: { Fmt.mhz($0) }
                            )
                            .frame(height: 88)
                        }
                        GraphPanel(title: "Power", scale: Fmt.watts(wattsMax)) {
                            TimeGraph(
                                samples: store.history,
                                series: [GraphSeries(value: { $0.power?.gpuW }, fill: .soft)],
                                color: Palette.gpu,
                                window: range.seconds,
                                maxValue: wattsMax,
                                rows: 2,
                                columns: range.gridColumns,
                                inspectable: true,
                                format: { Fmt.watts($0) }
                            )
                            .frame(height: 88)
                        }
                    }
                }

                if g?.memUsed != nil {
                    GraphPanel(title: "Memory in use", scale: Fmt.bytes(memMax)) {
                        TimeGraph(
                            samples: store.history,
                            series: [GraphSeries(value: { $0.gpus[id]?.memUsed }, fill: .soft)],
                            color: Palette.gpu,
                            window: range.seconds,
                            maxValue: memMax,
                            rows: 2,
                            columns: range.gridColumns,
                            inspectable: true,
                            format: { Fmt.bytes($0) }
                        )
                        .frame(height: 72)
                    }
                }
            }
            .contextMenu { GraphMenuContent { EmptyView() } }

            MetricStrip {
                Metric(label: "Utilization", value: Fmt.pct(g?.util))
                Metric(label: "Frequency", value: Fmt.mhz(g?.mhz))
                Metric(label: "Temperature", value: Fmt.temp(store.latest?.temps?.gpu))
                Metric(label: "Power", value: Fmt.watts(power?.gpuW))
            }

            DetailsGrid {
                DetailTable(title: "Graphics", rows: [
                    DetailRow("Chipset", gpu.name),
                    gpu.vendor.map { DetailRow("Vendor", $0) },
                    gpu.cores.map { DetailRow("GPU cores", String($0)) },
                    gpu.metal.map { DetailRow("Metal support", $0) },
                    DetailRow("Memory", gpu.dedicatedMemory.map { Fmt.bytes($0) } ?? "Shared with system"),
                    g?.memUsed.map { DetailRow("Memory in use", Fmt.bytes($0)) },
                ])
                DetailTable(title: "Activity", rows: [
                    g?.active.map { DetailRow("Active residency", Fmt.pct($0)) },
                    g?.mhz.map { DetailRow("Average frequency", Fmt.mhz($0)) },
                    power?.gpuW.map { DetailRow("GPU power", Fmt.watts($0)) },
                    power?.aneW.map { DetailRow("Neural Engine power", Fmt.watts($0)) },
                ])
                // Displays are driven by the first GPU on Apple silicon Macs.
                DetailTable(
                    title: "Displays",
                    rows: gpu.id == "0" ? store.info.displays.map { DetailRow($0.name, $0.resolution) } : []
                )
            }
        }
    }
}
