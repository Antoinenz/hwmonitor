import SwiftUI

struct CPUView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    @AppStorage(PrefKey.cpuMode) private var mode: CPUGraphMode = .overall
    @AppStorage(PrefKey.kernelTimes) private var kernelTimes = false

    var body: some View {
        let cpu = store.info.cpu
        let s = store.latest
        let temps = s?.temps
        let power = s?.power

        PerfPage(title: "CPU", subtitle: cpu.model) {
            options
        } content: {
            GraphPanel(
                title: mode.title,
                scale: mode == .temperature ? "110 °C" : "100%",
                axis: range.axisLabel
            ) {
                graph(coreCount: s?.cpu.cores.count ?? cpu.logical)
                    .flexibleGraphHeight()
            }
            .contextMenu { GraphMenuContent { options } }

            ElevationCallout(features: "Speed and power")

            MetricStrip {
                Metric(label: "Utilization", value: Fmt.pct(s?.cpu.total))
                Metric(label: "Speed", value: Fmt.mhz(s?.cpu.speedMHz))
                Metric(
                    label: "Temperature",
                    value: Fmt.temp(temps?.cpu),
                    legend: mode == .temperature ? Legend(color: Palette.temperature) : nil
                )
                Metric(label: "Power", value: Fmt.watts(power?.cpuW))
            }

            DetailsGrid {
                DetailTable(title: "Activity", rows: [
                    DetailRow("User", Fmt.pct(s?.cpu.user)),
                    DetailRow("System", Fmt.pct(s?.cpu.sys)),
                    DetailRow("Idle", s.map { Fmt.pct(100 - $0.cpu.total) } ?? Fmt.dash),
                    DetailRow("Processes", Fmt.count(s?.cpu.processes)),
                    DetailRow("Threads", Fmt.count(s?.cpu.threads)),
                    DetailRow("Load average", s.map { sample in
                        sample.cpu.load.map { String(format: "%.2f", $0) }.joined(separator: "  ·  ")
                    } ?? Fmt.dash),
                    DetailRow("Up time", Fmt.uptime(s?.cpu.uptime)),
                ])
                DetailTable(title: "Processor", rows: processorRows(cpu))
                DetailTable(title: "Thermals", rows: [
                    temps?.performanceCores.map { DetailRow("Performance cores", Fmt.temp($0)) },
                    temps?.efficiencyCores.map { DetailRow("Efficiency cores", Fmt.temp($0)) },
                    temps?.cpuMax.map { DetailRow("Hottest sensor", Fmt.temp($0)) },
                    temps?.soc.map { DetailRow("System on chip", Fmt.temp($0)) },
                    temps?.battery.map { DetailRow("Battery", Fmt.temp($0)) },
                    s.map { DetailRow("Thermal state", Fmt.thermalLabel($0.thermalState)) },
                    power?.thermal.map { DetailRow("Thermal pressure", $0) },
                ])
            }

            TopProcesses(sort: .cpu)
        }
    }

    @ViewBuilder private var options: some View {
        Picker("Change Graph To", selection: $mode) {
            ForEach(CPUGraphMode.allCases) { mode in
                Text(mode.menuLabel).tag(mode)
            }
        }
        .pickerStyle(.inline)
        Toggle("Show Kernel Times", isOn: $kernelTimes)
    }

    @ViewBuilder private func graph(coreCount: Int) -> some View {
        switch mode {
        case .logical where coreCount > 0:
            CoreGrid(samples: store.history, count: coreCount, window: range.seconds, kernel: kernelTimes)
        case .temperature:
            TimeGraph(
                samples: store.history,
                series: [
                    GraphSeries(value: { $0.temps?.cpu }, fill: .soft, label: "Avg"),
                    GraphSeries(value: { $0.temps?.cpuMax }, dashed: true, label: "Max"),
                ],
                color: Palette.temperature,
                window: range.seconds,
                maxValue: 110,
                columns: range.gridColumns,
                inspectable: true,
                format: { Fmt.temp($0) }
            )
        default:
            TimeGraph(
                samples: store.history,
                series: kernelTimes
                    ? [
                        GraphSeries(value: { $0.cpu.total }, fill: .soft, label: "Total"),
                        GraphSeries(value: { $0.cpu.sys }, fill: .strong, label: "Kernel"),
                    ]
                    : SeriesLibrary.cpu,
                color: Palette.cpu,
                window: range.seconds,
                maxValue: 100,
                columns: range.gridColumns,
                inspectable: true
            )
        }
    }

    private func processorRows(_ cpu: CPUStaticInfo) -> [DetailRow?] {
        let cores: String
        if let p = cpu.performanceCores, let e = cpu.efficiencyCores {
            cores = "\(cpu.physical) (\(p) performance, \(e) efficiency)"
        } else {
            cores = cpu.physical > 0 ? String(cpu.physical) : Fmt.dash
        }
        var l1: String?
        if let i = cpu.l1iBytes, let d = cpu.l1dBytes {
            l1 = "\(Fmt.bytes(Double(i), digits: 0)) + \(Fmt.bytes(Double(d), digits: 0)) per core"
        }
        return [
            DetailRow("Cores", cores),
            DetailRow("Logical processors", cpu.logical > 0 ? String(cpu.logical) : Fmt.dash),
            DetailRow("Sockets", String(cpu.sockets)),
            cpu.baseMHz.map { DetailRow("Base speed", Fmt.mhz($0)) },
            cpu.virtualization.map { DetailRow("Virtualization", $0 ? "Enabled" : "Not supported") },
            l1.map { DetailRow("L1 cache", $0) },
            cpu.l2Bytes.map { DetailRow("L2 cache", Fmt.bytes(Double($0))) },
            cpu.l3Bytes.map { DetailRow("L3 cache", Fmt.bytes(Double($0))) },
            store.info.modelID.map { DetailRow("Model", $0) },
        ]
    }
}

/// One small graph per logical processor.
private struct CoreGrid: View {
    var samples: [Sample]
    var count: Int
    var window: TimeInterval
    var kernel: Bool

    private var columns: Int {
        if count <= 4 { return max(1, count) }
        if count <= 16 { return 4 }
        if count <= 24 { return 6 }
        return 8
    }

    var body: some View {
        let cols = columns
        let rows = max(1, (count + cols - 1) / cols)
        VStack(spacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<cols, id: \.self) { col in
                        let index = row * cols + col
                        if index < count {
                            TimeGraph(
                                samples: samples,
                                series: series(for: index),
                                color: Palette.cpu,
                                window: window,
                                maxValue: 100,
                                rows: 2,
                                columns: 3,
                                lineWidth: 1.25,
                                cornerRadius: 6,
                                inspectable: true
                            )
                            .overlay(alignment: .topLeading) {
                                Text(verbatim: "\(index)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func series(for index: Int) -> [GraphSeries] {
        var list = [GraphSeries(value: { $0.cpu.cores[safe: index] }, fill: .soft)]
        if kernel {
            // Per-core kernel time isn't reported separately; scale by the overall ratio.
            list.append(GraphSeries(value: { s in
                s.cpu.total > 0 ? (s.cpu.cores[safe: index] ?? 0) * (s.cpu.sys / s.cpu.total) : 0
            }, fill: .strong))
        }
        return list
    }
}
