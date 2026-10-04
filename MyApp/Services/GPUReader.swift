import Foundation
import IOKit
import Metal

/// GPU utilisation from each IOAccelerator's PerformanceStatistics; static
/// details from the matching Metal device.
nonisolated enum GPUReader {
    static func staticInfo() -> [GPUInfo] {
        let metal = MTLCopyAllDevices()
        var list: [GPUInfo] = []
        IOKitUtil.forEachService("IOAccelerator") { accelerator in
            let index = list.count
            let registryID = IOKitUtil.registryID(accelerator)
            let device = metal.first { $0.registryID == registryID } ?? metal[safe: index]
            let model = IOKitUtil.property(accelerator, "model") as? String
            let name = model ?? device?.name ?? "GPU \(index)"
            list.append(GPUInfo(
                id: String(index),
                name: name,
                vendor: name.hasPrefix("Apple") ? "Apple" : nil,
                cores: (IOKitUtil.property(accelerator, "gpu-core-count") as? NSNumber)?.intValue,
                metal: device.map { $0.supportsFamily(.metal3) ? "Metal 3" : "Metal 2" },
                dedicatedMemory: device.flatMap { $0.hasUnifiedMemory ? nil : Double($0.recommendedMaxWorkingSetSize) }
            ))
        }
        if list.isEmpty {
            list = metal.enumerated().map { index, device in
                GPUInfo(id: String(index), name: device.name, metal: device.supportsFamily(.metal3) ? "Metal 3" : "Metal 2")
            }
        }
        return list
    }

    static func read() -> [String: GPUSample] {
        var result: [String: GPUSample] = [:]
        var index = 0
        IOKitUtil.forEachService("IOAccelerator") { accelerator in
            defer { index += 1 }
            guard let stats = IOKitUtil.property(accelerator, "PerformanceStatistics") as? [String: Any] else { return }
            let value = { (key: String) in (stats[key] as? NSNumber)?.doubleValue }
            let util = value("Device Utilization %") ?? value("GPU Activity(%)") ?? 0
            result[String(index)] = GPUSample(
                util: min(100, util),
                renderer: value("Renderer Utilization %"),
                tiler: value("Tiler Utilization %"),
                memUsed: value("In use system memory") ?? value("vramUsedBytes"),
                memAlloc: value("Alloc system memory")
            )
        }
        return result
    }
}
