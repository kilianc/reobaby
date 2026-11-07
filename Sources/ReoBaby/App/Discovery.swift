import Darwin
import Foundation

/// Finds Reolink cameras on the local network, with no account needed: every host on this Mac's
/// IPv4 subnets that accepts RTSP (TCP 554) and answers the Reolink HTTP API, which replies
/// "please login first" in its own JSON shape.
enum Discovery {
    struct Result {
        /// Addresses of the Reolink cameras found, in numeric order.
        var hosts: [String]
        /// macOS refused every connection on the spot: ReoBaby isn't allowed on the local network.
        var blocked: Bool
    }

    /// Searches every local subnet. Takes a second or two.
    static func find() async -> Result {
        let sweep = await Task.detached(priority: .userInitiated) { openHosts(candidateHosts(), port: 554) }.value
        let found = await withTaskGroup(of: String?.self) { group in
            for host in sweep.open {
                group.addTask { await CameraAPI(host: host, user: "", password: "", timeout: 3).isReolink() ? host : nil }
            }
            var found: [String] = []
            for await host in group { if let host { found.append(host) } }
            return found
        }
        return Result(hosts: found.sorted { (address($0) ?? 0) < (address($1) ?? 0) }, blocked: sweep.blocked)
    }

    /// Every other address on this Mac's Wi-Fi and Ethernet subnets (`en*`, so VPN tunnels and
    /// virtual-machine bridges are left alone). A subnet wider than /22 is narrowed to the /24
    /// around this Mac, so a sweep stays short.
    static func candidateHosts() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var hosts: [String] = []
        var seen = Set<UInt32>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let flags = Int32(ifa.ifa_flags)
            guard String(cString: ifa.ifa_name).hasPrefix("en"), flags & IFF_UP != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard ip & 0xFFFF_0000 != 0xA9FE_0000 else { continue } // 169.254/16: no DHCP here
            if netmask < 0xFFFF_FC00 { netmask = 0xFFFF_FF00 }
            let network = ip & netmask, broadcast = network | ~netmask
            guard broadcast > network &+ 1 else { continue }
            for host in (network + 1)..<broadcast where host != ip && seen.insert(host).inserted {
                hosts.append("\(host >> 24).\(host >> 16 & 0xFF).\(host >> 8 & 0xFF).\(host & 0xFF)")
            }
        }
        return hosts
    }

    /// The hosts that accept a TCP connection on `port` within `timeout`. Connects to a batch of
    /// hosts at once with non-blocking sockets, so a /24 takes under a second. `blocked` is set
    /// when every connect failed immediately with "no route to host", which is how macOS turns
    /// away an app without Local Network permission.
    static func openHosts(_ hosts: [String], port: UInt16, timeout: TimeInterval = 0.8) -> (open: [String], blocked: Bool) {
        // Apps start with room for 256 open files; a batch needs one socket per host.
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        if limit.rlim_cur < 2048 {
            limit.rlim_cur = min(2048, limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        let batch = max(32, Int(limit.rlim_cur) - 128)
        var open: [String] = []
        var attempts = 0, refusedOnTheSpot = 0
        for start in stride(from: 0, to: hosts.count, by: batch) {
            var pending: [(fd: Int32, host: String)] = []
            for host in hosts[start..<min(start + batch, hosts.count)] {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { continue }
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                attempts += 1
                if rc == 0 || errno == EINPROGRESS {
                    pending.append((fd, host))
                } else {
                    if errno == EHOSTUNREACH { refusedOnTheSpot += 1 }
                    close(fd)
                }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while !pending.isEmpty {
                let ms = Int32(deadline.timeIntervalSinceNow * 1000)
                guard ms > 0 else { break }
                var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                guard poll(&fds, nfds_t(fds.count), ms) > 0 else { break }
                var waiting: [(fd: Int32, host: String)] = []
                for (i, p) in fds.enumerated() {
                    guard p.revents != 0 else { waiting.append(pending[i]); continue }
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    if error == 0 { open.append(pending[i].host) }
                    close(p.fd)
                }
                pending = waiting
            }
            pending.forEach { close($0.fd) }
        }
        return (open, attempts > 0 && refusedOnTheSpot == attempts)
    }

    private static func address(_ host: String) -> UInt32? {
        var addr = in_addr()
        return inet_pton(AF_INET, host, &addr) == 1 ? UInt32(bigEndian: addr.s_addr) : nil
    }
}
