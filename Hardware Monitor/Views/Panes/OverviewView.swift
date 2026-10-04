import SwiftUI

/// At-a-glance dashboard. The sidebar already carries a live graph for every
/// device, so this page summarises instead: health, gauges, power flow,
/// thermals, throughput, storage and the busiest processes.
struct OverviewView: View {
    @Environment(MetricsStore.self) private var store
    @Binding var selection: Pane?

    var body: some View {
        let info = store.info
        let s = store.latest

        PerfPage(title: "Overview", subtitle: Fmt.join([info.hostName, info.osVersion])) {
            HeroCard(info: info, sample: s)

            HStack(spacing: 12) {
                GaugeTile(
                    title: "CPU",
                    value: s?.cpu.total,
                    detail: s?.cpu.speedMHz.map { Fmt.mhz($0) } ?? info.cpu.model,
                    colors: [Palette.cpu.opacity(0.6), Palette.cpu]
                ) { selection = .cpu }
                GaugeTile(
                    title: "GPU",
                    value: s?.gpus["0"]?.util,
                    detail: s?.gpus["0"]?.mhz.map { Fmt.mhz($0) } ?? info.gpus.first?.name ?? Fmt.dash,
                    colors: [Palette.gpu.opacity(0.6), Palette.gpu]
                ) { if let gpu = info.gpus.first { selection = .gpu(gpu.id) } }
                GaugeTile(
                    title: "Memory",
                    value: s?.mem.pressure,
                    detail: s.map { "\(Fmt.bytes($0.mem.used)) of \(Fmt.bytes($0.mem.total, digits: 0))" } ?? Fmt.dash,
                    colors: Palette.pressureRamp
                ) { selection = .memory }
                GaugeTile(
                    title: "Temperature",
                    value: s?.temps?.cpu.map { $0 / 110 * 100 },
                    display: Fmt.temp(s?.temps?.cpu),
                    detail: s.map { "Thermal state \(Fmt.thermalLabel($0.thermalState).lowercased())" } ?? Fmt.dash,
                    colors: [.green, .yellow, .orange, .red]
                ) { selection = .cpu }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                PowerFlowCard(power: s?.power, battery: s?.battery) { selection = .power }
                ThermalsCard(temps: s?.temps, disks: info.disks)
                ThroughputCard(sample: s, networks: info.networks)
                StorageCard(disks: info.disks) { id in selection = .disk(id) }
            }

            DashboardCard {
                TopProcesses(sort: .cpu, count: 5)
            }
        }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    var info: SystemInfo
    var sample: Sample?

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(info.hostName.isEmpty ? "This Mac" : info.hostName)
                    .font(.system(size: 22, weight: .semibold))
                Text(info.modelName ?? info.modelID ?? "Mac")
                    .foregroundStyle(.secondary)
                Text(Fmt.join([info.cpu.model, Fmt.bytes(info.memory.total, digits: 0) + " memory", info.osVersion]))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                StatusPill(status: SystemStatus(sample: sample))
                    .padding(.top, 6)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Up time")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Fmt.uptime(sample?.cpu.uptime))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: sample?.cpu.uptime)
                Text(Fmt.join([sample?.cpu.processes.map { "\($0) processes" }, sample?.cpu.threads.map { "\($0.formatted()) threads" }]))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Palette.cpu.opacity(0.10), Palette.gpu.opacity(0.06), Color.primary.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
    }
}

/// The single most important thing to know right now.
private struct SystemStatus: Equatable {
    var symbol: String
    var text: String
    var color: Color

    init(sample: Sample?) {
        guard let s = sample else {
            self.init("hourglass", "Gathering data…", .secondary)
            return
        }
        if s.thermalState == .critical || s.thermalState == .serious {
            self.init("flame.fill", "Thermal throttling likely", .red)
        } else if s.mem.level >= 4 {
            self.init("memorychip.fill", "Memory pressure is critical", .red)
        } else if let battery = s.battery, !battery.externalConnected, battery.percent <= 15 {
            self.init("battery.25percent", "Battery low — \(Int(battery.percent))%", .orange)
        } else if let temp = s.temps?.cpu, temp >= 90 {
            self.init("thermometer.high", "CPU is running hot", .orange)
        } else if s.mem.level >= 2 {
            self.init("memorychip", "Memory pressure is elevated", .orange)
        } else if s.cpu.total >= 90 {
            self.init("gauge.with.dots.needle.100percent", "CPU is fully loaded", .yellow)
        } else {
            self.init("checkmark.circle.fill", "Everything looks normal", .green)
        }
    }

    private init(_ symbol: String, _ text: String, _ color: Color) {
        self.symbol = symbol
        self.text = text
        self.color = color
    }
}

private struct StatusPill: View {
    var status: SystemStatus

    var body: some View {
        Label(status.text, systemImage: status.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.14), in: Capsule())
            .contentTransition(.symbolEffect(.replace))
            .animation(.smooth, value: status)
    }
}

// MARK: - Gauges

private struct GaugeTile: View {
    var title: String
    /// 0–100, or nil while unknown.
    var value: Double?
    /// Centre text; defaults to the value as a percentage.
    var display: String?
    var detail: String
    var colors: [Color]
    var action: () -> Void

    var body: some View {
        let text = display ?? Fmt.pct(value)
        let parts = Fmt.splitUnit(text)
        let fraction = min(max((value ?? 0) / 100, 0), 1)

        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    Circle()
                        .trim(from: 0, to: 0.75 * fraction)
                        .stroke(
                            AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .animation(.smooth(duration: 0.7), value: fraction)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(parts.figure)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(parts.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .rotationEffect(.degrees(-135))
                    .animation(.smooth(duration: 0.4), value: text)
                }
                .rotationEffect(.degrees(135))
                .frame(width: 96, height: 96)

                VStack(spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
        }
        .buttonStyle(DashboardButtonStyle())
        .accessibilityLabel("\(title) \(text), \(detail)")
    }
}

// MARK: - Cards

/// Shared card chrome.
private struct DashboardCard<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DashboardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.06 : 0.035), in: shape)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.spring(duration: 0.2), value: configuration.isPressed)
        }
    }
}

/// Adapter → Mac → battery, with live watts and animated arrows showing direction.
private struct PowerFlowCard: View {
    var power: PowerSample?
    var battery: BatteryStatus?
    var action: () -> Void

    var body: some View {
        let plugged: Bool = battery?.externalConnected ?? ((power?.adapterW ?? 0) > 0.5)
        let batteryW: Double = battery?.batteryWatts ?? 0
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Power", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    FlowNode(symbol: plugged ? "powerplug.fill" : "powerplug", title: "Adapter",
                             value: plugged ? Fmt.watts(power?.adapterW) : "Unplugged", active: plugged)
                    FlowArrow(active: plugged, reversed: false)
                    FlowNode(symbol: "laptopcomputer", title: "System", value: Fmt.watts(power?.systemW), active: true)
                    if let battery {
                        FlowArrow(active: abs(batteryW) > 0.1, reversed: batteryW < 0)
                        FlowNode(
                            symbol: batterySymbol(battery),
                            title: "\(Int(battery.percent))%",
                            value: abs(batteryW) > 0.1 ? Fmt.watts(abs(batteryW)) : battery.stateLabel,
                            active: abs(batteryW) > 0.1
                        )
                    }
                }

                if let p = power {
                    ComponentBar(parts: [
                        ("CPU", p.cpuW, Palette.cpu),
                        ("GPU", p.gpuW, Palette.gpu),
                        ("ANE", p.aneW, Palette.memory),
                        ("DRAM", p.dramW, Palette.disk),
                    ], total: p.systemW)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DashboardButtonStyle())
    }

    private func batterySymbol(_ b: BatteryStatus) -> String {
        if b.isCharging { return "battery.100percent.bolt" }
        switch b.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct FlowNode: View {
    var symbol: String
    var title: String
    var value: String
    var active: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(active ? Palette.power : Color.secondary)
                .frame(height: 24)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowArrow: View {
    var active: Bool
    var reversed: Bool

    var body: some View {
        Image(systemName: reversed ? "chevron.left.2" : "chevron.right.2")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Palette.power : Color.secondary.opacity(0.4))
            .symbolEffect(.variableColor.iterative, isActive: active)
            .padding(.bottom, 26)
    }
}

/// Thin stacked bar of component power with a legend.
private struct ComponentBar: View {
    var parts: [(name: String, watts: Double?, color: Color)]
    var total: Double?

    var body: some View {
        let known = parts.filter { ($0.watts ?? 0) > 0.005 }
        let sum = max(total ?? 0, known.reduce(0) { $0 + ($1.watts ?? 0) }, 0.001)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(known, id: \.name) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, geometry.size.width * (part.watts ?? 0) / sum))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
            .animation(.smooth(duration: 0.6), value: known.map { $0.watts ?? 0 })

            HStack(spacing: 12) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 6, height: 6)
                        Text(part.name).foregroundStyle(.secondary)
                        Text(Fmt.watts(part.watts)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// Temperature chips tinted by how hot each sensor is.
private struct ThermalsCard: View {
    var temps: TemperatureSample?
    var disks: [DiskInfo]

    var body: some View {
        let chips: [(String, Double?)] = [
            ("Performance cores", temps?.performanceCores),
            ("Efficiency cores", temps?.efficiencyCores),
            ("GPU", temps?.gpu),
            ("System on chip", temps?.soc),
            ("SSD", disks.contains(where: \.hasNANDSensor) ? temps?.nand : nil),
            ("Battery", temps?.battery),
        ].filter { $0.1 != nil }

        DashboardCard(title: "Thermals", symbol: "thermometer.medium") {
            if chips.isEmpty {
                Text("No temperature sensors available")
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(chips, id: \.0) { name, value in
                        TemperatureChip(name: name, celsius: value ?? 0)
                    }
                }
            }
        }
    }
}

private struct TemperatureChip: View {
    var name: String
    var celsius: Double

    private var tint: Color {
        switch celsius {
        case ..<50: .green
        case ..<70: .yellow
        case ..<85: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.temp(celsius))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.smooth, value: Int(celsius))
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.smooth, value: tint)
    }
}

/// Total network and disk throughput as large figures.
private struct ThroughputCard: View {
    var sample: Sample?
    var networks: [NetworkInfo]

    var body: some View {
        let recv = sample?.net.values.reduce(0) { $0 + $1.recv }
        let send = sample?.net.values.reduce(0) { $0 + $1.send }
        let read = sample?.disks.values.reduce(0) { $0 + $1.read }
        let write = sample?.disks.values.reduce(0) { $0 + $1.write }

        DashboardCard(title: "Activity", symbol: "arrow.up.arrow.down") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    figure("arrow.down", "Download", Fmt.bits(recv), Palette.network)
                    figure("arrow.up", "Upload", Fmt.bits(send), Palette.network)
                }
                GridRow {
                    figure("doc.text.magnifyingglass", "Disk read", Fmt.rate(read), Palette.disk)
                    figure("square.and.pencil", "Disk write", Fmt.rate(write), Palette.disk)
                }
            }
            if let primary = networks.first(where: { $0.kind != .vpn }) {
                Text(Fmt.join([primary.title, primary.ipv4.first]))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func figure(_ symbol: String, _ label: String, _ value: String, _ color: Color) -> some View {
        let parts = Fmt.splitUnit(value)
        return VStack(alignment: .leading, spacing: 1) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.figure)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .animation(.smooth(duration: 0.4), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Capacity rings for each mounted volume.
private struct StorageCard: View {
    var disks: [DiskInfo]
    var open: (String) -> Void

    var body: some View {
        let volumes = disks.flatMap { disk in disk.volumes.map { (disk: disk, volume: $0) } }
        DashboardCard(title: "Storage", symbol: "internaldrive") {
            if volumes.isEmpty {
                Text("No volumes").foregroundStyle(.tertiary)
            }
            ForEach(volumes, id: \.volume.id) { entry in
                let v = entry.volume
                let fraction = v.size > 0 ? v.used / v.size : 0
                Button { open(entry.disk.id) } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 6)
                            Circle()
                                .trim(from: 0, to: fraction)
                                .stroke(Palette.disk.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(Fmt.pct(fraction * 100))
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.headline)
                            Text("\(Fmt.bytes(v.available, base: 1000)) free of \(Fmt.bytes(v.size, base: 1000))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
