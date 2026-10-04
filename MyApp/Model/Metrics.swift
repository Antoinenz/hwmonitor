import Foundation

// MARK: - Static hardware info

nonisolated struct CPUStaticInfo: Equatable, Sendable {
    var model: String
    var logical: Int
    var physical: Int
    var performanceCores: Int?
    var efficiencyCores: Int?
    var sockets: Int
    var l1iBytes: Int?
    var l1dBytes: Int?
    var l2Bytes: Int?
    var l3Bytes: Int?
    var baseMHz: Double?
    var virtualization: Bool?
}

nonisolated struct MemoryStaticInfo: Equatable, Sendable {
    var total: Double
    var type: String?
    var manufacturer: String?
}

nonisolated struct VolumeInfo: Identifiable, Equatable, Sendable {
    var id: String { mount }
    var name: String
    var mount: String
    var size: Double
    var available: Double
    var used: Double { max(0, size - available) }
}

nonisolated struct DiskInfo: Identifiable, Equatable, Sendable {
    /// Whole-disk BSD name, e.g. `disk0`.
    var id: String
    var index: Int
    var model: String
    /// SSD, HDD, Disk image, Removable or Disk.
    var type: String
    var interconnect: String?
    var location: String?
    var size: Double
    var removable: Bool
    var systemDisk: Bool = false
    var volumes: [VolumeInfo] = []

    var title: String {
        let names = volumes.map(\.name).joined(separator: ", ")
        return names.isEmpty ? "Disk \(index)" : "Disk \(index) (\(names))"
    }

    /// The internal SSD is the only disk with an on-die (NAND) temperature sensor.
    var hasNANDSensor: Bool { location == "Internal" && type == "SSD" }
}

nonisolated enum NetworkKind: String, Sendable {
    case wifi, ethernet, vpn, other

    var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .vpn: "VPN tunnel"
        case .other: "Network"
        }
    }
}

nonisolated struct NetworkInfo: Identifiable, Equatable, Sendable {
    /// BSD interface, e.g. `en0`.
    var id: String
    /// Hardware port name, e.g. Wi-Fi.
    var name: String
    var kind: NetworkKind
    var mac: String?
    var ipv4: [String]
    var ipv6: [String]

    var title: String { kind == .vpn ? "VPN (\(id))" : name }
}

nonisolated struct DisplayInfo: Equatable, Sendable {
    var name: String
    var resolution: String
}

nonisolated struct GPUInfo: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var vendor: String?
    var cores: Int?
    var metal: String?
    /// Dedicated video memory; nil when memory is shared with the system.
    var dedicatedMemory: Double?
}

nonisolated struct SystemInfo: Equatable, Sendable {
    var hostName: String = ""
    var osVersion: String = "macOS"
    var modelID: String?
    var cpu = CPUStaticInfo(model: "Processor", logical: 0, physical: 0, sockets: 1)
    var memory = MemoryStaticInfo(total: Double(ProcessInfo.processInfo.physicalMemory))
    var disks: [DiskInfo] = []
    var networks: [NetworkInfo] = []
    var gpus: [GPUInfo] = []
    var displays: [DisplayInfo] = []
}

// MARK: - Per-second samples

nonisolated struct CPUClusterSample: Sendable {
    /// IOReport cluster name, e.g. ECPU, PCPU0.
    var name: String
    var mhz: Double
    /// Active residency, 0–100.
    var active: Double

    var isEfficiency: Bool { name.hasPrefix("E") }

    var label: String {
        let base = isEfficiency ? "Efficiency" : "Performance"
        let suffix = name.dropFirst(4)
        return suffix.isEmpty ? base : "\(base) \(suffix)"
    }
}

nonisolated struct CPUSample: Sendable {
    var total: Double
    var user: Double
    var sys: Double
    var cores: [Double]
    /// Activity-weighted average frequency across clusters.
    var speedMHz: Double?
    var clusters: [CPUClusterSample] = []
    var processes: Int?
    var threads: Int?
    var uptime: TimeInterval
    var load: [Double]
}

nonisolated struct MemorySample: Sendable {
    /// 0–100, derived from the kernel's free-memory level.
    var pressure: Double
    /// 1 normal, 2 warning, 4 critical.
    var level: Int
    var total: Double
    var used: Double
    var app: Double
    var wired: Double
    var compressed: Double
    var cached: Double
    var free: Double
    var swapUsed: Double
    var swapTotal: Double
}

nonisolated struct DiskSample: Sendable {
    /// Percent of the interval the device was busy.
    var active: Double
    /// Bytes per second.
    var read: Double
    var write: Double
    var responseMs: Double
}

nonisolated struct NetSample: Sendable {
    /// Bytes per second.
    var send: Double
    var recv: Double
}

nonisolated struct GPUSample: Sendable {
    /// Utilisation, 0–100: frequency-weighted active residency on Apple
    /// silicon (matches macmon/powermetrics), the driver's figure elsewhere.
    var util: Double
    /// Plain active residency, 0–100 (Apple silicon only).
    var active: Double?
    var mhz: Double?
    var memUsed: Double?
}

nonisolated struct PowerSample: Sendable {
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?
    var dramW: Double?
    /// Whole-system draw (SMC PSTR).
    var systemW: Double?
    /// Power coming in from the adapter (SMC PDTR).
    var adapterW: Double?
    /// Battery charge (+) or discharge (−) power (SMC PPBR is unsigned; sign from battery current).
    var batteryW: Double?
}

nonisolated struct TemperatureSample: Sendable {
    /// Average CPU temperature (°C).
    var cpu: Double?
    var cpuMax: Double?
    var performanceCores: Double?
    var efficiencyCores: Double?
    var gpu: Double?
    var soc: Double?
    /// Internal SSD (NAND) temperature.
    var nand: Double?
    var battery: Double?
}

nonisolated struct Sample: Sendable {
    /// Seconds since 1970, aligned to a wall-clock second.
    var t: TimeInterval
    var cpu: CPUSample
    var mem: MemorySample
    var disks: [String: DiskSample]
    var net: [String: NetSample]
    var gpus: [String: GPUSample]
    var power: PowerSample?
    var temps: TemperatureSample?
    var thermalState: ProcessInfo.ThermalState
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
