import Foundation
import Darwin
import SystemConfiguration

/// Active network adapters (hardware ports with an address, plus VPN tunnels)
/// and their per-second throughput from the kernel's 64-bit interface counters.
nonisolated final class NetworkReader {
    private struct Port {
        var name: String
        var device: String
        var mac: String?
        var kind: NetworkKind
    }

    private struct Addresses {
        var ipv4: [String] = []
        var ipv6: [String] = []
        var linkLocal6: [String] = []
    }

    private var ports: [Port] = []
    private(set) var interfaces: [NetworkInfo] = []
    private var previous: [String: (t: TimeInterval, rx: UInt64, tx: UInt64)] = [:]

    func rediscover() {
        loadPorts()
        refresh()
    }

    private func loadPorts() {
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        ports = all.compactMap { iface in
            guard let device = SCNetworkInterfaceGetBSDName(iface) as String? else { return nil }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? device
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            let kind: NetworkKind =
                type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet
                : device.hasPrefix("utun") || device.hasPrefix("ipsec") || device.hasPrefix("ppp") ? .vpn
                : .other
            return Port(name: name, device: device, mac: SCNetworkInterfaceGetHardwareAddressString(iface) as String?, kind: kind)
        }
    }

    func refresh() {
        if ports.isEmpty { loadPorts() }
        let addresses = Self.addresses()
        var infos: [NetworkInfo] = []
        for port in ports {
            guard let addr = addresses[port.device], !(addr.ipv4.isEmpty && addr.ipv6.isEmpty) else { continue }
            infos.append(NetworkInfo(
                id: port.device,
                name: port.name,
                kind: port.kind,
                mac: port.mac,
                ipv4: addr.ipv4,
                ipv6: addr.ipv6.isEmpty ? addr.linkLocal6 : addr.ipv6
            ))
        }
        // VPN tunnels with an IPv4 address (e.g. Tailscale, WireGuard).
        for device in addresses.keys.sorted() where device.hasPrefix("utun") {
            guard let addr = addresses[device], !addr.ipv4.isEmpty,
                  !infos.contains(where: { $0.id == device })
            else { continue }
            infos.append(NetworkInfo(id: device, name: "VPN", kind: .vpn, mac: nil, ipv4: addr.ipv4, ipv6: addr.ipv6))
        }
        interfaces = infos
    }

    private static func addresses() -> [String: Addresses] {
        var result: [String: Addresses] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [:] }
        defer { freeifaddrs(head) }

        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr,
                  (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            var address = cString(host)
            if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }

            let name = String(cString: ifa.pointee.ifa_name)
            if family == AF_INET {
                result[name, default: Addresses()].ipv4.append(address)
            } else if address.lowercased().hasPrefix("fe80") {
                result[name, default: Addresses()].linkLocal6.append(address)
            } else {
                result[name, default: Addresses()].ipv6.append(address)
            }
        }
        return result
    }

    /// Reads 64-bit byte counters for every interface via NET_RT_IFLIST2.
    private static func counters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[cString(name)] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    func read(at t: TimeInterval) -> [String: NetSample] {
        let totals = Self.counters()
        var result: [String: NetSample] = [:]
        for info in interfaces {
            guard let cur = totals[info.id] else { continue }
            let prev = previous[info.id]
            previous[info.id] = (t, cur.rx, cur.tx)
            guard let prev, t > prev.t else {
                result[info.id] = NetSample(send: 0, recv: 0)
                continue
            }
            let dt = t - prev.t
            result[info.id] = NetSample(
                send: cur.tx >= prev.tx ? Double(cur.tx - prev.tx) / dt : 0,
                recv: cur.rx >= prev.rx ? Double(cur.rx - prev.rx) / dt : 0
            )
        }
        return result
    }
}
