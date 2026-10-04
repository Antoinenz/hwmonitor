import Foundation
import IOKit
import IOKit.ps

nonisolated struct ChargerProfile: Identifiable, Equatable, Sendable {
    var id: Int { index }
    var index: Int
    /// Volts.
    var voltage: Double
    /// Amps.
    var current: Double
    var watts: Double { voltage * current }
}

nonisolated struct PowerAdapterInfo: Equatable, Sendable {
    var name: String?
    var ratedWatts: Double?
    /// Negotiated voltage (V) and current limit (A).
    var voltage: Double?
    var current: Double?
    var isWireless: Bool
    /// USB-PD profiles the charger offers.
    var profiles: [ChargerProfile]
    var activeProfile: Int?
}

nonisolated struct BatteryStatus: Sendable {
    var percent: Double
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    /// Minutes to empty or full; nil while macOS is still estimating.
    var minutesRemaining: Int?
    var voltage: Double
    /// Amps; positive while charging, negative while discharging.
    var current: Double
    var temperature: Double?
    var cycleCount: Int?
    var designCycles: Int?
    /// mAh.
    var designCapacity: Double?
    var fullChargeCapacity: Double?
    var nominalCapacity: Double?
    var remainingCapacity: Double?
    /// e.g. "Good", "Service Recommended".
    var condition: String?
    var serial: String?
    var deviceName: String?
    var adapter: PowerAdapterInfo?
    /// Charge current/voltage into the cells (A, V).
    var chargingCurrent: Double?
    var chargingVoltage: Double?
    /// Watts drawn by the system from the adapter, and lost converting it.
    var systemLoad: Double?
    var adapterLoss: Double?

    /// Power into (+) or out of (−) the battery, in watts.
    var batteryWatts: Double { voltage * current }

    /// Maximum capacity relative to design, as shown in System Settings.
    var health: Double? {
        guard let design = designCapacity, design > 0, let full = nominalCapacity ?? fullChargeCapacity else { return nil }
        return min(100, full / design * 100)
    }

    var stateLabel: String {
        if isCharging { return "Charging" }
        if fullyCharged && externalConnected { return "Charged" }
        if externalConnected { return "Not charging" }
        return "On battery"
    }
}

/// Battery, charger and power-telemetry details from the AppleSmartBattery
/// service (no special privileges required).
nonisolated enum BatteryReader {
    static func read() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = raw?.takeRetainedValue() as? [String: Any],
              (props["BatteryInstalled"] as? Bool) ?? true
        else { return nil }

        func number(_ dict: [String: Any], _ key: String) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }
        func signed(_ dict: [String: Any], _ key: String) -> Double? {
            (dict[key] as? NSNumber).map { Double($0.int64Value) }
        }

        let battery = props["BatteryData"] as? [String: Any] ?? [:]
        let charger = props["ChargerData"] as? [String: Any] ?? [:]
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        let external = (props["ExternalConnected"] as? Bool) ?? false
        let charging = (props["IsCharging"] as? Bool) ?? false

        var adapter: PowerAdapterInfo?
        if external, let details = props["AdapterDetails"] as? [String: Any] {
            let menu = details["UsbHvcMenu"] as? [[String: Any]] ?? []
            adapter = PowerAdapterInfo(
                name: (details["Name"] as? String) ?? (details["Description"] as? String).map(Self.describe),
                ratedWatts: number(details, "Watts"),
                voltage: number(details, "AdapterVoltage").map { $0 / 1000 },
                current: number(details, "Current").map { $0 / 1000 },
                isWireless: (details["IsWireless"] as? Bool) ?? false,
                profiles: menu.compactMap { item in
                    guard let index = number(item, "Index"), let mv = number(item, "MaxVoltage"), let ma = number(item, "MaxCurrent") else { return nil }
                    return ChargerProfile(index: Int(index), voltage: mv / 1000, current: ma / 1000)
                }.sorted { $0.index < $1.index },
                activeProfile: number(details, "UsbHvcHvcIndex").map(Int.init)
            )
        }

        let minutes: Int? = {
            let key = charging ? "AvgTimeToFull" : "AvgTimeToEmpty"
            guard let value = number(props, key), value > 0, value < 65535 else { return nil }
            return Int(value)
        }()
        let systemLoad = number(telemetry, "SystemLoad").map { $0 / 1000 }

        return BatteryStatus(
            percent: number(props, "CurrentCapacity") ?? 0,
            isCharging: charging,
            externalConnected: external,
            fullyCharged: (props["FullyCharged"] as? Bool) ?? false,
            minutesRemaining: minutes,
            voltage: (number(props, "Voltage") ?? 0) / 1000,
            current: (signed(props, "InstantAmperage") ?? signed(props, "Amperage") ?? 0) / 1000,
            temperature: number(props, "Temperature").map { $0 / 100 },
            cycleCount: number(props, "CycleCount").map(Int.init),
            designCycles: number(props, "DesignCycleCount9C").map(Int.init),
            designCapacity: number(props, "DesignCapacity") ?? number(battery, "DesignCapacity"),
            fullChargeCapacity: number(props, "AppleRawMaxCapacity") ?? number(battery, "FullChargeCapacity"),
            nominalCapacity: number(props, "NominalChargeCapacity") ?? number(battery, "NominalChargeCapacity"),
            remainingCapacity: number(props, "AppleRawCurrentCapacity") ?? number(battery, "RemainingCapacity"),
            condition: condition(),
            serial: props["Serial"] as? String,
            deviceName: props["DeviceName"] as? String,
            adapter: adapter,
            chargingCurrent: number(charger, "ChargingCurrent").map { $0 / 1000 },
            chargingVoltage: number(charger, "ChargingVoltage").map { $0 / 1000 },
            systemLoad: systemLoad.flatMap { $0 > 0 ? $0 : nil },
            adapterLoss: number(telemetry, "AdapterEfficiencyLoss").map { $0 / 1000 }
        )
    }

    /// "pd charger" → "USB-C PD charger".
    private static func describe(_ description: String) -> String {
        description.lowercased() == "pd charger" ? "USB-C PD charger" : description.capitalized
    }

    /// Battery condition as reported to the Battery settings pane.
    private static func condition() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            if let condition = description["BatteryHealthCondition"] as? String, !condition.isEmpty { return condition }
            return description[kIOPSBatteryHealthKey] as? String
        }
        return nil
    }
}
