import Foundation
import IOKit

/// Physical disks from the IORegistry, per-second I/O from each
/// IOBlockStorageDriver's statistics, and mounted volumes grouped by disk.
nonisolated final class DiskReader {
    private struct Counters {
        var t: TimeInterval
        var bytesRead: Double
        var bytesWrite: Double
        var ops: Double
        var timeNs: Double
    }

    private(set) var disks: [DiskInfo] = []
    private var previous: [String: Counters] = [:]
    /// Volume BSD name → physical whole-disk BSD name.
    private var physicalCache: [String: String] = [:]

    // MARK: Discovery

    func discover() {
        var found: [DiskInfo] = []
        IOKitUtil.forEachService("IOBlockStorageDriver") { driver in
            guard let media = IOKitUtil.child(driver) else { return }
            defer { IOObjectRelease(media) }
            guard let bsd = IOKitUtil.property(media, "BSD Name") as? String,
                  bsd.hasPrefix("disk"), let index = Int(bsd.dropFirst(4))
            else { return }

            let size = (IOKitUtil.property(media, "Size") as? NSNumber)?.doubleValue ?? 0
            let removable = (IOKitUtil.property(media, "Removable") as? Bool) ?? false

            var device: [String: Any] = [:]
            var proto: [String: Any] = [:]
            var deviceClass = ""
            if let parent = IOKitUtil.parent(driver) {
                device = IOKitUtil.property(parent, "Device Characteristics") as? [String: Any] ?? [:]
                proto = IOKitUtil.property(parent, "Protocol Characteristics") as? [String: Any] ?? [:]
                deviceClass = IOKitUtil.className(parent)
                IOObjectRelease(parent)
            }

            let trimmed = { (key: String) in
                (device[key] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
            let interconnect = proto["Physical Interconnect"] as? String
            let isImage = deviceClass.contains("DiskImage") || interconnect == "Virtual Interface"
            let medium = device["Medium Type"] as? String
            let type: String =
                isImage ? "Disk image"
                : medium == "Solid State" ? "SSD"
                : medium == "Rotational" ? "HDD"
                : removable ? "Removable"
                : "Disk"
            let model = [trimmed("Vendor Name"), trimmed("Product Name")].compactMap { $0 }.joined(separator: " ")

            found.append(DiskInfo(
                id: bsd,
                index: index,
                model: model.isEmpty ? (isImage ? "Disk Image" : bsd) : model,
                type: type,
                interconnect: interconnect,
                location: proto["Physical Interconnect Location"] as? String,
                size: size,
                removable: removable
            ))
        }
        found.sort { $0.index < $1.index }
        // Keep the volumes we already know until the next refresh.
        for i in found.indices {
            if let old = disks.first(where: { $0.id == found[i].id }) {
                found[i].volumes = old.volumes
                found[i].systemDisk = old.systemDisk
            }
        }
        disks = found
        physicalCache.removeAll()
    }

    // MARK: Volumes

    func refreshVolumes() {
        // getfsstat with MNT_NOWAIT returns cached mount info without touching any
        // filesystem, so a stalled network share can never block sampling.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return }
        var mounts: [statfs] = Array(repeating: statfs(), count: Int(count))
        let got = getfsstat(&mounts, Int32(MemoryLayout<statfs>.stride * Int(count)), MNT_NOWAIT)
        guard got > 0 else { return }

        let physicalIDs = Set(disks.map(\.id))
        var volumesByDisk: [String: [VolumeInfo]] = [:]
        var systemDisk: String?
        var seenContainers: Set<String> = []

        var local: [(fs: statfs, from: String, mount: String)] = []
        for fs in mounts.prefix(Int(got)) {
            let from = Self.string(fs.f_mntfromname)
            let mount = Self.string(fs.f_mntonname)
            guard from.hasPrefix("/dev/disk") else { continue }
            // Skip hidden system volumes (Preboot, VM, Data…), but always keep "/".
            let hidden = (fs.f_flags & UInt32(MNT_DONTBROWSE)) != 0
            if hidden && mount != "/" { continue }
            local.append((fs, from, mount))
        }
        // Visit "/" first so it wins over other volumes in the same APFS container.
        local.sort { $0.mount == "/" && $1.mount != "/" }

        for entry in local {
            let bsd = String(entry.from.dropFirst(5))
            guard let physical = physicalDisk(forBSD: bsd, among: physicalIDs) else { continue }

            // Synthesized APFS containers share one pool: show one volume per container.
            let whole = Self.match(bsd, #"^disk\d+"#) ?? bsd
            let container = physicalIDs.contains(whole) ? (Self.match(bsd, #"^disk\d+s\d+"#) ?? whole) : whole
            guard seenContainers.insert(container).inserted else { continue }

            let blockSize = Double(entry.fs.f_bsize)
            let size = Double(entry.fs.f_blocks) * blockSize
            var available = Double(entry.fs.f_bavail) * blockSize
            let url = URL(fileURLWithPath: entry.mount, isDirectory: true)
            var keys: Set<URLResourceKey> = [.volumeLocalizedNameKey]
            let readOnly = (entry.fs.f_flags & UInt32(MNT_RDONLY)) != 0
            // Finder-style free space (includes purgeable space) on writable volumes.
            if !readOnly { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
            let values = try? url.resourceValues(forKeys: keys)
            if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
                available = min(size, Double(important))
            }
            let name = values?.volumeLocalizedName ?? (entry.mount == "/" ? "Macintosh HD" : url.lastPathComponent)
            if entry.mount == "/" { systemDisk = physical }
            volumesByDisk[physical, default: []].append(
                VolumeInfo(name: name, mount: entry.mount, size: size, available: available)
            )
        }

        for i in disks.indices {
            disks[i].volumes = volumesByDisk[disks[i].id] ?? []
            disks[i].systemDisk = disks[i].id == systemDisk
        }
    }

    /// Walks up the IORegistry from a volume's media object to the physical
    /// disk's block-storage driver (through any APFS container).
    private func physicalDisk(forBSD bsd: String, among physicalIDs: Set<String>) -> String? {
        if let cached = physicalCache[bsd] { return cached }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard entry != 0 else { return nil }
        var result: String?
        for _ in 0..<40 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0, let media = IOKitUtil.child(entry) {
                let name = IOKitUtil.property(media, "BSD Name") as? String
                IOObjectRelease(media)
                if let name, physicalIDs.contains(name) {
                    result = name
                    break
                }
            }
            guard let parent = IOKitUtil.parent(entry) else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        IOObjectRelease(entry)
        if let result { physicalCache[bsd] = result }
        return result
    }

    // MARK: Per-second statistics

    func read(at t: TimeInterval) -> [String: DiskSample] {
        var current: [String: Counters] = [:]
        IOKitUtil.forEachService("IOBlockStorageDriver") { driver in
            guard let stats = IOKitUtil.property(driver, "Statistics") as? [String: Any],
                  let media = IOKitUtil.child(driver)
            else { return }
            let bsd = IOKitUtil.property(media, "BSD Name") as? String
            IOObjectRelease(media)
            guard let bsd else { return }
            let value = { (key: String) in (stats[key] as? NSNumber)?.doubleValue ?? 0 }
            current[bsd] = Counters(
                t: t,
                bytesRead: value("Bytes (Read)"),
                bytesWrite: value("Bytes (Write)"),
                ops: value("Operations (Read)") + value("Operations (Write)"),
                timeNs: value("Total Time (Read)") + value("Total Time (Write)")
            )
        }

        var result: [String: DiskSample] = [:]
        for disk in disks {
            guard let cur = current[disk.id] else { continue }
            let prev = previous[disk.id]
            previous[disk.id] = cur
            guard let prev, cur.t > prev.t else {
                result[disk.id] = DiskSample(active: 0, read: 0, write: 0, responseMs: 0)
                continue
            }
            let dt = cur.t - prev.t
            let dOps = max(0, cur.ops - prev.ops)
            let dTime = max(0, cur.timeNs - prev.timeNs)
            result[disk.id] = DiskSample(
                active: min(100, dTime / (dt * 1e9) * 100),
                read: max(0, cur.bytesRead - prev.bytesRead) / dt,
                write: max(0, cur.bytesWrite - prev.bytesWrite) / dt,
                responseMs: dOps > 0 ? dTime / dOps / 1e6 : 0
            )
        }
        return result
    }

    /// Converts a fixed-size C char tuple (e.g. `f_mntonname`) to a string.
    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
