import SwiftUI

nonisolated enum PrefKey {
    static let range = "graphRange"
    static let cpuMode = "cpuGraphMode"
    static let kernelTimes = "showKernelTimes"
    static let memMode = "memoryGraphMode"
    static let appearance = "appearance"
    static let selectedPane = "selectedPane"
    static let showMenuBar = "showMenuBarExtra"
    static let compactMode = "compactMode"
    static let keepOnTop = "keepOnTop"
    static let menuBarItems = "menuBarItems"
}

nonisolated enum TimeRange: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case oneHour = "1h"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .oneHour: "1 hour"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .oneHour: 3600
        }
    }

    var axisLabel: String {
        switch self {
        case .oneMinute: "60 seconds"
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        }
    }

    /// Vertical grid divisions: every 10 s, 1 min and 10 min respectively.
    var gridColumns: Int {
        switch self {
        case .oneMinute: 6
        case .fiveMinutes: 5
        case .oneHour: 6
        }
    }
}

nonisolated enum CPUGraphMode: String, CaseIterable, Identifiable {
    case overall, logical, temperature

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .overall: "Overall Utilization"
        case .logical: "Logical Processors"
        case .temperature: "Temperature"
        }
    }

    var title: String {
        switch self {
        case .overall: "% Utilization"
        case .logical: "Utilization per logical processor"
        case .temperature: "Temperature"
        }
    }
}

nonisolated enum MemoryGraphMode: String, CaseIterable, Identifiable {
    case pressure, usage

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .pressure: "Memory Pressure"
        case .usage: "Memory Used"
        }
    }
}

nonisolated enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Only data is coloured; chrome stays neutral.
nonisolated enum Palette {
    static let cpu = Color.blue
    static let memory = Color.purple
    static let disk = Color.green
    static let network = Color.orange
    static let gpu = Color.pink
    static let temperature = Color.orange
    static let power = Color.teal
    /// Memory pressure blends green (bottom) → yellow → red (top) by height.
    static let pressureRamp: [Color] = [.green, .yellow, .red]
}

/// Values that can be shown in the menu bar, in display order.
nonisolated enum MenuBarItem: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, cpuTemperature, power, battery, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU usage"
        case .gpu: "GPU usage"
        case .memory: "Memory pressure"
        case .cpuTemperature: "CPU temperature"
        case .power: "System power"
        case .battery: "Battery"
        case .network: "Network throughput"
        case .disk: "Disk activity"
        }
    }

    /// Short caption drawn above the value.
    var caption: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .cpuTemperature: "TEMP"
        case .power: "POWER"
        case .battery: "BATT"
        case .network: "NET"
        case .disk: "DISK"
        }
    }

    static func decode(_ raw: String) -> [MenuBarItem] {
        let chosen = Set(raw.split(separator: ",").compactMap { MenuBarItem(rawValue: String($0)) })
        return allCases.filter(chosen.contains)
    }

    static func encode(_ items: [MenuBarItem]) -> String {
        items.map(\.rawValue).joined(separator: ",")
    }
}
