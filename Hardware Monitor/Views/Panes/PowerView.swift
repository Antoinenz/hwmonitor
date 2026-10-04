import SwiftUI

struct PowerView: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(PrefKey.range) private var range: TimeRange = .oneMinute

    var body: some View {
        let s = store.latest
        let power = s?.power
        let battery = s?.battery
        let systemMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 10) { sample in
            [sample.power?.systemW ?? 0, sample.power?.adapterW ?? 0]
        }
        let componentMax = GraphMath.autoMax(store.history, window: range.seconds, floor: 2) { sample in
            let p = sample.power
            return [p?.cpuW ?? 0, p?.gpuW ?? 0, p?.aneW ?? 0, p?.dramW ?? 0]
        }

        PerfPage(title: "Power", subtitle: subtitle(battery)) {
            if let battery {
                BatteryHero(battery: battery, temperature: battery.temperature ?? s?.temps?.battery)
            }

            VStack(alignment: .leading, spacing: 20) {
                GraphPanel(title: "System power", scale: Fmt.watts(systemMax), axis: range.axisLabel) {
                    TimeGraph(
                        samples: store.history,
                        series: [
                            GraphSeries(value: { $0.power?.systemW }, fill: .soft, label: "System"),
                            GraphSeries(value: { $0.power?.adapterW }, dashed: true, label: "Adapter"),
                        ],
                        color: Palette.power,
                        window: range.seconds,
                        maxValue: systemMax,
                        columns: range.gridColumns,
                        inspectable: true,
                        format: { Fmt.watts($0) }
                    )
                    .flexibleGraphHeight(reserve: battery == nil ? 520 : 640, min: 120, max: 320)
                }

                GraphPanel(title: "Components", scale: Fmt.watts(componentMax)) {
                    TimeGraph(
                        samples: store.history,
                        series: [
                            GraphSeries(value: { $0.power?.cpuW }, label: "CPU", color: Palette.cpu),
                            GraphSeries(value: { $0.power?.gpuW }, label: "GPU", color: Palette.gpu),
                            GraphSeries(value: { $0.power?.aneW }, label: "ANE", color: Palette.memory),
                            GraphSeries(value: { $0.power?.dramW }, label: "DRAM", color: Palette.disk),
                        ],
                        color: Palette.power,
                        window: range.seconds,
                        maxValue: componentMax,
                        rows: 2,
                        columns: range.gridColumns,
                        inspectable: true,
                        format: { Fmt.watts($0) }
                    )
                    .frame(height: 96)
                }
            }
            .contextMenu { GraphMenuContent { EmptyView() } }

            MetricStrip {
                Metric(label: "System", value: Fmt.watts(power?.systemW), legend: Legend(color: Palette.power))
                Metric(label: "Adapter input", value: Fmt.watts(power?.adapterW), legend: Legend(color: Palette.power, dashed: true))
                Metric(
                    label: battery.map { $0.batteryWatts >= 0 ? "Into battery" : "From battery" } ?? "Battery",
                    value: battery.map { Fmt.watts(abs($0.batteryWatts)) } ?? Fmt.dash
                )
                Metric(label: "Battery health", value: Fmt.pct(battery?.health))
            }

            DetailsGrid {
                DetailTable(title: "Components", rows: [
                    DetailRow("CPU", Fmt.watts(power?.cpuW)),
                    DetailRow("GPU", Fmt.watts(power?.gpuW)),
                    DetailRow("Neural Engine", Fmt.watts(power?.aneW)),
                    power?.dramW.flatMap { $0 > 0 ? DetailRow("Memory", Fmt.watts($0)) : nil },
                    battery?.adapterLoss.map { DetailRow("Adapter conversion loss", Fmt.watts($0)) },
                ])
                if let battery {
                    DetailTable(title: "Battery", rows: batteryRows(battery))
                    DetailTable(title: "Power adapter", rows: adapterRows(battery))
                    if let profiles = battery.adapter?.profiles, !profiles.isEmpty {
                        ChargerProfiles(profiles: profiles, active: battery.adapter?.activeProfile)
                    }
                }
            }
        }
    }

    private func subtitle(_ battery: BatteryStatus?) -> String {
        guard let battery else { return "No battery" }
        return Fmt.join([
            Fmt.pct(battery.percent),
            battery.stateLabel,
            battery.externalConnected ? battery.adapter?.ratedWatts.map { "\(Int($0)) W adapter" } : nil,
        ])
    }

    private func batteryRows(_ b: BatteryStatus) -> [DetailRow?] {
        [
            b.condition.map { DetailRow("Condition", $0) },
            b.health.map { DetailRow("Maximum capacity", Fmt.pct($0, digits: 1)) },
            b.cycleCount.map { cycles in
                DetailRow("Cycle count", b.designCycles.map { "\(cycles) of \($0)" } ?? String(cycles))
            },
            b.designCapacity.map { DetailRow("Design capacity", "\(Int($0)) mAh") },
            b.fullChargeCapacity.map { DetailRow("Full charge capacity", "\(Int($0)) mAh") },
            b.remainingCapacity.map { DetailRow("Remaining charge", "\(Int($0)) mAh") },
            DetailRow("Voltage", String(format: "%.2f V", b.voltage)),
            DetailRow("Current", String(format: "%+.2f A", b.current)),
            b.serial.map { DetailRow("Serial number", $0) },
        ]
    }

    private func adapterRows(_ b: BatteryStatus) -> [DetailRow?] {
        guard b.externalConnected, let adapter = b.adapter else {
            return [DetailRow("Connected", "No")]
        }
        return [
            adapter.name.map { DetailRow("Type", adapter.isWireless ? "\($0) (wireless)" : $0) },
            adapter.ratedWatts.map { DetailRow("Rated power", "\(Int($0)) W") },
            adapter.voltage.flatMap { v in adapter.current.map { DetailRow("Negotiated", String(format: "%.0f V × %.2f A", v, $0)) } },
            b.systemLoad.map { DetailRow("System draw", Fmt.watts($0)) },
            b.chargingCurrent.flatMap { $0 > 0 ? DetailRow("Charging current", String(format: "%.2f A", $0)) : nil },
            b.chargingVoltage.flatMap { $0 > 0 ? DetailRow("Charging voltage", String(format: "%.2f V", $0)) : nil },
        ]
    }
}

/// Large battery gauge with charge level, state and time remaining.
private struct BatteryHero: View {
    var battery: BatteryStatus
    var temperature: Double?

    private var tint: Color {
        if battery.isCharging || battery.externalConnected { return .green }
        if battery.percent <= 10 { return .red }
        if battery.percent <= 20 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(spacing: 24) {
            BatteryGlyph(level: battery.percent / 100, tint: tint, charging: battery.isCharging, plugged: battery.externalConnected)
                .frame(width: 120, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.pct(battery.percent).dropLast())
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(verbatim: "%")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .animation(.smooth, value: battery.percent)
                Text(Fmt.join([battery.stateLabel, remaining]))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                if let health = battery.health {
                    statRow("Health", Fmt.pct(health))
                }
                if let cycles = battery.cycleCount {
                    statRow("Cycles", String(cycles))
                }
                if let temperature {
                    statRow("Temperature", Fmt.temp(temperature))
                }
            }
            .font(.callout)
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var remaining: String? {
        guard let minutes = battery.minutesRemaining else { return nil }
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return battery.isCharging ? "\(text) until full" : "\(text) remaining"
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

/// Drawn battery: rounded body, terminal nub, animated fill and a bolt/plug badge.
private struct BatteryGlyph: View {
    var level: Double
    var tint: Color
    var charging: Bool
    var plugged: Bool

    var body: some View {
        GeometryReader { geometry in
            let nub = geometry.size.width * 0.06
            let bodyWidth = geometry.size.width - nub - 3
            HStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2.5)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(8, (bodyWidth - 10) * min(max(level, 0), 1)))
                        .padding(5)
                        .animation(.smooth(duration: 0.8), value: level)
                    if charging || plugged {
                        Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
                            .font(.system(size: geometry.size.height * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                            .frame(maxWidth: .infinity)
                            .symbolEffect(.pulse, isActive: charging)
                    }
                }
                .frame(width: bodyWidth)
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: nub, height: geometry.size.height * 0.36)
            }
        }
        .accessibilityLabel("Battery \(Int(level * 100)) percent")
    }
}

/// The USB-PD voltage/current profiles the connected charger offers.
private struct ChargerProfiles: View {
    var profiles: [ChargerProfile]
    var active: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Charger capabilities")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(profiles) { profile in
                    let isActive = profile.index == active
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isActive ? Color.green : Color.primary.opacity(0.2))
                            .frame(width: 7, height: 7)
                        Text(String(format: "%.0f V", profile.voltage))
                            .frame(width: 44, alignment: .leading)
                        Text(String(format: "%.2f A", profile.current))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(String(format: "%.0f W", profile.watts))
                            .foregroundStyle(.secondary)
                        if isActive {
                            Text("In use")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
