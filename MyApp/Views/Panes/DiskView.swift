import SwiftUI

struct DiskView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute
    var diskID: String

    var body: some View {
        if let disk = store.info.disks.first(where: { $0.id == diskID }) {
            content(disk)
        } else if !store.isReady {
            Color.clear
        } else {
            DeviceGoneView(title: "This disk is no longer connected", systemImage: "externaldrive.badge.xmark")
        }
    }

    private func content(_ disk: DiskInfo) -> some View {
        let d = store.latest?.disks[diskID]
        let temp = disk.hasNANDSensor ? store.latest?.temps?.nand : nil
        let rateMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 100_000) { s in
            [s.disks[diskID]?.read ?? 0, s.disks[diskID]?.write ?? 0]
        }

        return PerfPage(title: disk.title, subtitle: disk.model) {
            VStack(alignment: .leading, spacing: 20) {
                GraphPanel(title: "Active time", scale: "100%", axis: range.axisLabel) {
                    TimeGraph(
                        samples: store.history,
                        series: SeriesLibrary.diskActive(diskID),
                        color: Palette.disk,
                        window: range.seconds,
                        maxValue: 100,
                        columns: range.gridColumns,
                        inspectable: true
                    )
                    .flexibleGraphHeight(reserve: 600, min: 140, max: 400)
                }
                GraphPanel(title: "Transfer rate", scale: Fmt.rate(rateMax), axis: range.axisLabel) {
                    TimeGraph(
                        samples: store.history,
                        series: [
                            GraphSeries(value: { $0.disks[diskID]?.read }, fill: .soft, label: "Read"),
                            GraphSeries(value: { $0.disks[diskID]?.write }, dashed: true, label: "Write"),
                        ],
                        color: Palette.disk,
                        window: range.seconds,
                        maxValue: rateMax,
                        rows: 2,
                        columns: range.gridColumns,
                        inspectable: true,
                        format: { Fmt.rate($0) }
                    )
                    .frame(height: 96)
                }
            }
            .contextMenu { GraphMenuContent { EmptyView() } }

            MetricStrip {
                Metric(label: "Active time", value: Fmt.pct(d?.active))
                Metric(label: "Read", value: Fmt.rate(d?.read), legend: Legend(color: Palette.disk))
                Metric(label: "Write", value: Fmt.rate(d?.write), legend: Legend(color: Palette.disk, dashed: true))
                if let temp {
                    Metric(label: "Temperature", value: Fmt.temp(temp))
                } else {
                    Metric(label: "Response time", value: Fmt.ms(d?.responseMs))
                }
            }

            DetailsGrid {
                DetailTable(title: "Device", rows: [
                    DetailRow("Model", disk.model),
                    temp != nil ? DetailRow("Response time", Fmt.ms(d?.responseMs)) : nil,
                    DetailRow("Capacity", Fmt.bytes(disk.size, base: 1000)),
                    DetailRow("Type", disk.type),
                    disk.interconnect.map { DetailRow("Interface", $0) },
                    disk.location.map { DetailRow("Location", $0) },
                    DetailRow("System disk", disk.systemDisk ? "Yes" : "No"),
                ])
                if !disk.volumes.isEmpty {
                    VolumesList(volumes: disk.volumes)
                }
            }
        }
    }
}

private struct VolumesList: View {
    var volumes: [VolumeInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Volumes")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(volumes) { volume in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(volume.name).lineLimit(1)
                            Text(volume.mount)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text("\(Fmt.bytes(volume.used, base: 1000)) of \(Fmt.bytes(volume.size, base: 1000))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                        UsageBar(fraction: volume.size > 0 ? volume.used / volume.size : 0, color: Palette.disk)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
