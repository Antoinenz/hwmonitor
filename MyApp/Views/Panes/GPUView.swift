import SwiftUI

struct GPUView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    var gpuID: String

    private struct Engine: Identifiable {
        var id: String { label }
        var label: String
        var value: (GPUSample) -> Double?
    }

    private static let engines = [
        Engine(label: "Device", value: { $0.util }),
        Engine(label: "Renderer", value: { $0.renderer }),
        Engine(label: "Tiler", value: { $0.tiler }),
    ]

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
        // Hide engines this GPU doesn't report.
        let engines = Self.engines.filter { engine in
            engine.label == "Device" || g.map { engine.value($0) != nil } ?? true
        }
        // Scale to what's drawn (memory in use), not the much larger allocation.
        let memMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 256 * 1_048_576, bytes: true) { s in
            [s.gpus[id]?.memUsed ?? 0]
        }

        return PerfPage(title: "GPU \(gpu.id)", subtitle: gpu.name) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ForEach(engines) { engine in
                        GraphPanel(title: engine.label, scale: Fmt.pct(g.flatMap(engine.value))) {
                            TimeGraph(
                                samples: store.history,
                                series: [GraphSeries(value: { s in s.gpus[id].flatMap(engine.value) }, fill: .soft)],
                                color: Palette.gpu,
                                window: range.seconds,
                                maxValue: 100,
                                columns: 3,
                                inspectable: true
                            )
                            .flexibleGraphHeight(reserve: 560, min: 96, max: 240)
                        }
                    }
                }
                if g?.memUsed != nil {
                    GraphPanel(title: "Memory in use", scale: Fmt.bytes(memMax), axis: range.axisLabel) {
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
                        .frame(height: 80)
                    }
                }
            }
            .contextMenu { GraphMenuContent { EmptyView() } }

            ElevationCallout(features: "Frequency and power")

            MetricStrip {
                Metric(label: "Utilization", value: Fmt.pct(g?.util))
                Metric(label: "Temperature", value: Fmt.temp(store.latest?.temps?.gpu))
                Metric(label: "Frequency", value: Fmt.mhz(power?.gpuMHz))
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
                // Displays are driven by the first GPU on Apple silicon Macs.
                DetailTable(
                    title: "Displays",
                    rows: gpu.id == "0" ? store.info.displays.map { DetailRow($0.name, $0.resolution) } : []
                )
            }
        }
    }
}
