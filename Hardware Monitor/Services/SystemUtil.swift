import Foundation
import IOKit

/// Converts a NUL-terminated C character buffer into a Swift string.
nonisolated func cString(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

nonisolated enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = cString(buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

nonisolated enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var error: String
    }

    /// Runs a system tool synchronously. Call off the main actor.
    static func run(_ path: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Small regular-expression helpers for parsing tool output.
nonisolated enum RX {
    static func groups(in text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func number(in text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> Double? {
        groups(in: text, pattern, options: options)?.first.flatMap { Double($0) }
    }

    static func allGroups(in text: String, _ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<max(1, match.numberOfRanges)).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

nonisolated enum IOKitUtil {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Calls `body` for each service of the given class. Objects are released afterwards.
    static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// First parent in the service plane. The caller must release it.
    static func parent(_ entry: io_registry_entry_t) -> io_registry_entry_t? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { return nil }
        return parent
    }

    /// First child in the service plane. The caller must release it.
    static func child(_ entry: io_registry_entry_t) -> io_registry_entry_t? {
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(entry, kIOServicePlane, &child) == KERN_SUCCESS, child != 0 else { return nil }
        return child
    }

    static func className(_ entry: io_registry_entry_t) -> String {
        (IOObjectCopyClass(entry)?.takeRetainedValue() as String?) ?? ""
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }
}
