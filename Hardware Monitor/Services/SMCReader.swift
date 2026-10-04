import Foundation
import IOKit

/// Read-only access to the System Management Controller (power rails, fans,
/// sensors). Available to unprivileged processes through the AppleSMC service.
nonisolated final class SMCReader {
    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// Mirrors the kernel's SMCParamStruct (80 bytes).
    private struct Param {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    struct Value {
        var type: String
        var bytes: [UInt8]

        /// Numeric interpretation of common SMC data types.
        var number: Double? {
            switch type {
            case "flt ":
                guard bytes.count >= 4 else { return nil }
                return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
            case "ui8 ": return bytes.first.map(Double.init)
            case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
            case "ui32":
                guard bytes.count >= 4 else { return nil }
                return Double(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
            case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
            default: return nil
            }
        }
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    var isAvailable: Bool { connection != 0 }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var outputSize = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &outputSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = Param()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo
        guard let output = call(&input) else { return nil }
        infoCache[key] = output.keyInfo
        return output.keyInfo
    }

    func read(_ key: String) -> Value? {
        guard connection != 0 else { return nil }
        let code = Self.fourCC(key)
        guard let info = info(code) else { return nil }
        var input = Param()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // kSMCReadKey
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(32, info.dataSize)))) }
        return Value(type: Self.string(info.dataType), bytes: bytes)
    }

    func number(_ key: String) -> Double? {
        read(key)?.number
    }

    /// Every key name the SMC exposes (several hundred on Apple silicon).
    func allKeys() -> [String] {
        guard let count = number("#KEY").map(Int.init) else { return [] }
        var keys: [String] = []
        for index in 0..<count {
            var input = Param()
            input.data8 = 8 // kSMCGetKeyFromIndex
            input.data32 = UInt32(index)
            if let output = call(&input) { keys.append(Self.string(output.key)) }
        }
        return keys
    }
}
