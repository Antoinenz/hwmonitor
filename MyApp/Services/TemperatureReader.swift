import Foundation

/// Thermal sensors (CPU clusters, GPU, SoC, NAND, battery) through the
/// IOHIDEventSystem. These functions aren't in the public headers, so they're
/// resolved at runtime; if any are missing the reader simply reports nothing.
nonisolated final class TemperatureReader: @unchecked Sendable {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias ClientSetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias EventGetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private struct API {
        var create: ClientCreate
        var setMatching: ClientSetMatching
        var copyServices: ClientCopyServices
        var copyProperty: ServiceCopyProperty
        var copyEvent: ServiceCopyEvent
        var getFloat: EventGetFloatValue
    }

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let api: API?
    private let queue = DispatchQueue(label: "SystemMonitor.temperature", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var latest: (time: Date, sensors: [(name: String, value: Double)])?

    // Confined to `queue`.
    private var client: UnsafeMutableRawPointer?
    private var services: CFArray?
    private var names: [String] = []
    private var enumeratedAt = Date.distantPast

    init() {
        api = Self.loadAPI()
    }

    private static func loadAPI() -> API? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: EventGetFloatValue.self)
        else { return nil }
        return API(create: create, setMatching: setMatching, copyServices: copyServices,
                   copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }

    func start() {
        guard api != nil, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func enumerate(_ api: API, client: UnsafeMutableRawPointer) {
        guard let raw = api.copyServices(client) else { return }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        var found: [String] = []
        for i in 0..<CFArrayGetCount(array) {
            var name = "Sensor \(i)"
            if let service = CFArrayGetValueAtIndex(array, i),
               let property = api.copyProperty(service, "Product" as CFString),
               let product = Unmanaged<AnyObject>.fromOpaque(property).takeRetainedValue() as? String {
                name = product
            }
            found.append(name)
        }
        services = array
        names = found
        enumeratedAt = Date()
    }

    private func poll() {
        guard let api else { return }
        if client == nil {
            guard let created = api.create(kCFAllocatorDefault) else { return }
            // Apple vendor usage page / temperature sensor usage.
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = api.setMatching(created, matching)
            client = created
        }
        guard let client else { return }
        if services == nil || Date().timeIntervalSince(enumeratedAt) > 60 {
            enumerate(api, client: client)
        }
        guard let services else { return }

        var readings: [(name: String, value: Double)] = []
        for i in 0..<min(CFArrayGetCount(services), names.count) {
            guard let service = CFArrayGetValueAtIndex(services, i),
                  let event = api.copyEvent(service, Self.temperatureEventType, 0, 0)
            else { continue }
            let value = api.getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            if value > 0 && value < 150 {
                readings.append((names[i], (value * 10).rounded() / 10))
            }
        }
        lock.withLock { latest = (Date(), readings) }
    }

    /// Aggregated temperatures, or nil when no recent sensor data is available.
    func read() -> TemperatureSample? {
        guard let latest = lock.withLock({ latest }),
              Date().timeIntervalSince(latest.time) < 10,
              !latest.sensors.isEmpty
        else { return nil }
        let sensors = latest.sensors

        func pick(_ matches: (String) -> Bool) -> [Double] {
            sensors.filter { sensor in
                guard matches(sensor.name), !sensor.name.lowercased().contains("tcal") else { return false }
                // Power-gated MTR sensors (GPU/ANE at idle) report a flat 30.0 placeholder.
                return !(sensor.name.contains("MTR") && sensor.value == 30)
            }.map(\.value)
        }
        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        let pCores = pick { $0.contains("pACC") || $0.contains("PACC") }
        let eCores = pick { $0.contains("eACC") || $0.contains("EACC") }
        var cpu = pCores + eCores
        if cpu.isEmpty { cpu = pick { $0.lowercased().contains("tdie") } }
        if cpu.isEmpty { cpu = pick { $0.uppercased().contains("CPU") } }

        return TemperatureSample(
            cpu: average(cpu),
            cpuMax: cpu.max(),
            performanceCores: average(pCores),
            efficiencyCores: average(eCores),
            gpu: average(pick { $0.uppercased().contains("GPU") }),
            soc: average(pick { $0.uppercased().contains("SOC") || $0.uppercased().contains("PMGR") }),
            nand: average(pick { $0.uppercased().contains("NAND") }),
            battery: average(pick { $0.lowercased().contains("battery") || $0.lowercased().contains("gas gauge") })
        )
    }
}
