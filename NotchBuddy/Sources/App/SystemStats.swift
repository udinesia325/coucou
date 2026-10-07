import AppKit
import IOKit
import SwiftUI
#if !APPSTORE
import CoreLocation
import CoreWLAN
import IOBluetooth
#endif

// MARK: - Sampler (runs only while the Stats tab is on screen)

@MainActor
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    struct CPUSample { var user: Double; var system: Double }

    @Published private(set) var cpu: [CPUSample] = []
    @Published private(set) var memUsed: UInt64 = 0
    let memTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var diskName = "Disk"
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var ip: String?
    @Published private(set) var temperature: Double?
    @Published private(set) var fanRPM: Double?

    enum WiFi: Equatable {
        case off, searching, connected(String?), ethernet, unavailable
    }
    enum Bluetooth: Equatable {
        case off, on, connected([String]), unavailable
    }
    @Published private(set) var wifi: WiFi = .unavailable
    @Published private(set) var bluetooth: Bluetooth = .unavailable
    #if !APPSTORE
    /// The Wi-Fi name needs Location Services on macOS 14+.
    private let location = CLLocationManager()
    func requestWiFiName() {
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    static let historyLength = 40
    private let host = mach_host_self()
    private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastDisk: (read: UInt64, write: UInt64, at: Date)?
    private var lastNet: (counters: [String: (UInt32, UInt32)], at: Date)?
    private lazy var smc = SMC()

    /// Samples every 1.5 s until the calling task is cancelled.
    func run() async {
        while !Task.isCancelled {
            sample()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
        sampleNetwork()
        sampleRadios()
        temperature = smc?.temperature()
        fanRPM = smc?.fanRPM()
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastTicks = t }
        guard let p = lastTicks else { return }
        let user = Double((t.user &- p.user) &+ (t.nice &- p.nice))
        let system = Double(t.system &- p.system)
        let total = user + system + Double(t.idle &- p.idle)
        guard total > 0 else { return }
        cpu.append(CPUSample(user: user / total, system: system / total))
        if cpu.count > Self.historyLength { cpu.removeFirst(cpu.count - Self.historyLength) }
    }

    private func sampleMemory() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(vm.internal_page_count) - min(UInt64(vm.internal_page_count), UInt64(vm.purgeable_count))
        let pages = app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        memUsed = min(memTotal, pages * UInt64(getpagesize()))
    }

    private func sampleDisk() {
        let root = URL(fileURLWithPath: "/")
        if let v = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                                      .volumeAvailableCapacityForImportantUsageKey]),
           let total = v.volumeTotalCapacity {
            diskName = v.volumeLocalizedName ?? "Disk"
            diskTotal = Int64(total)
            diskUsed = Int64(total) - (v.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        let now = Date(), bytes = Self.diskBytes()
        if let last = lastDisk {
            let dt = max(0.1, now.timeIntervalSince(last.at))
            diskRead = Double(bytes.read &- last.read) / dt
            diskWrite = Double(bytes.write &- last.write) / dt
        }
        lastDisk = (bytes.read, bytes.write, now)
    }

    private static func diskBytes() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var read: UInt64 = 0, write: UInt64 = 0
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                read  += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return (read, write)
    }

    private func sampleRadios() {
        #if !APPSTORE
        if let iface = CWWiFiClient.shared().interface() {
            if !iface.powerOn() {
                wifi = .off
            } else if let ssid = iface.ssid() {
                wifi = .connected(ssid)
            } else if iface.rssiValue() != 0 {
                wifi = .connected(nil)          // associated, name hidden without Location
            } else {
                wifi = ip != nil ? .ethernet : .searching
            }
        } else {
            wifi = ip != nil ? .ethernet : .unavailable
        }
        if let host = IOBluetoothHostController.default(), host.addressAsString() != nil {
            if host.powerState != kBluetoothHCIPowerStateON {
                bluetooth = .off
            } else {
                let names = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
                    .filter { $0.isConnected() }
                    .map { $0.nameOrAddress ?? "Device" }
                bluetooth = names.isEmpty ? .on : .connected(names)
            }
        } else {
            bluetooth = .unavailable
        }
        #endif
    }

    private func sampleNetwork() {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return }
        defer { freeifaddrs(ifap) }
        // ponytail: en* only (Wi-Fi / Ethernet); VPN tunnels would double count. Add utun if needed.
        var counters: [String: (UInt32, UInt32)] = [:]
        var address: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                if let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee {
                    counters[name] = (data.ifi_ibytes, data.ifi_obytes)
                }
            case AF_INET where address == nil && ifa.ifa_flags & UInt32(IFF_UP) != 0:
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: buf)
                }
            default: break
            }
        }
        ip = address
        let now = Date()
        if let last = lastNet {
            let dt = max(0.1, now.timeIntervalSince(last.at))
            var inBytes: UInt64 = 0, outBytes: UInt64 = 0
            for (name, c) in counters {
                guard let old = last.counters[name] else { continue }
                // 32-bit counters wrap at 4 GB: wrapping subtraction still gives the delta.
                inBytes += UInt64(c.0 &- old.0)
                outBytes += UInt64(c.1 &- old.1)
            }
            netIn = Double(inBytes) / dt
            netOut = Double(outBytes) / dt
        }
        lastNet = (counters, now)
    }
}

// MARK: - SMC (temperature, fan). Not available in the sandboxed App Store build: shows "—".

private struct SMCParam {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    // Layout matches the kernel's SMCKeyData_t (80 bytes).
    var key: UInt32 = 0
    var vers = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

@MainActor
private final class SMC {
    private var conn: io_connect_t = 0
    // ponytail: first key that answers wins. Intel CPU proximity/die, then Apple Silicon P-core keys.
    private static let tempKeys = ["TC0P", "TC0D", "TC0E", "TC0F", "TC0H",
                                   "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp1h", "Tp1t", "Te05", "Tf04"]
    private var tempKey: String?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        // task_self_trap() == mach_task_self(); the mach_task_self_ global isn't usable under Swift 6.
        guard IOServiceOpen(service, task_self_trap(), 0, &conn) == KERN_SUCCESS else { return nil }
    }

    func temperature() -> Double? {
        if let key = tempKey { return read(key) }
        for key in Self.tempKeys {
            if let t = read(key), t > 1, t < 130 { tempKey = key; return t }
        }
        return nil
    }

    func fanRPM() -> Double? {
        guard let n = read("FNum"), n >= 1 else { return nil }
        return read("F0Ac")
    }

    private static func code(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return kr == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func read(_ key: String) -> Double? {
        var input = SMCParam()
        input.key = Self.code(key)
        input.data8 = 9  // kSMCGetKeyInfo
        guard let info = call(&input) else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5  // kSMCReadKey
        guard let out = call(&input) else { return nil }
        let b = out.bytes
        switch info.keyInfo.dataType {
        case Self.code("sp78"): return Double(Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))) / 256
        case Self.code("fpe2"): return Double(UInt16(b.0) << 8 | UInt16(b.1)) / 4
        case Self.code("flt "): return Double(Float(bitPattern: UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24))
        case Self.code("ui8 "): return Double(b.0)
        case Self.code("ui16"): return Double(UInt16(b.0) << 8 | UInt16(b.1))
        default: return nil
        }
    }
}

// MARK: - Stats view

struct StatsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var stats = SystemStats.shared

    private var active: Bool { state.mode == .expanded && state.view == .stats }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    cpuTile.frame(width: 190)
                    memoryTile
                    diskTile
                }
                HStack(spacing: 6) {
                    networkTile
                    bluetoothTile.frame(width: 190)
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        // 0 % CPU when hidden: sampling lives and dies with the tab.
        .task(id: active) {
            if active { await stats.run() }
        }
    }

    private var cpuTile: some View {
        let last = stats.cpu.last
        return StatTile(icon: "cpu", title: "CPU", trailing: stats.temperature.map { String(format: "%.0f°C", $0) }) {
            HStack(spacing: 6) {
                CPUSparkline(samples: stats.cpu)
                VStack(alignment: .leading, spacing: 2) {
                    Legend(color: Self.userColor, text: "User \(Self.pct(last?.user))")
                    Legend(color: Self.systemColor, text: "Sys \(Self.pct(last?.system))")
                    if let rpm = stats.fanRPM {
                        HStack(spacing: 3) {
                            Image(systemName: "fanblades").font(.system(size: 8))
                            Text("\(Int(rpm)) rpm").font(.system(size: 9.5).monospacedDigit())
                        }
                    }
                }
                .fixedSize()
            }
            .foregroundColor(Self.dim)
        }
    }

    private var memoryTile: some View {
        StatTile(icon: "memorychip", title: "RAM", trailing: Self.pct(Double(stats.memUsed) / Double(max(1, stats.memTotal)))) {
            Spacer(minLength: 0)
            UsedTotal(used: Int64(stats.memUsed), total: Int64(stats.memTotal), style: .memory)
            UsageBar(fraction: Double(stats.memUsed) / Double(max(1, stats.memTotal)))
        }
    }

    private var diskTile: some View {
        StatTile(icon: "internaldrive", title: stats.diskName, trailing: nil) {
            UsedTotal(used: stats.diskUsed, total: stats.diskTotal, style: .file)
            UsageBar(fraction: Double(stats.diskUsed) / Double(max(1, stats.diskTotal)))
            HStack(spacing: 4) {
                Text("R \(Self.rate(stats.diskRead))")
                Spacer(minLength: 0)
                Text("W \(Self.rate(stats.diskWrite))")
            }
            .font(.system(size: 9.5).monospacedDigit()).foregroundColor(Self.dim)
            .lineLimit(1)
        }
    }

    private var wifiLabel: (icon: String, text: String, color: Color) {
        switch stats.wifi {
        case .off:                 return ("wifi.slash", "Wi-Fi off", Self.dim)
        case .searching:           return ("wifi.exclamationmark", "Searching…", Color(hex: "#F5A524"))
        case .connected(let name): return ("wifi", name ?? "Wi-Fi", Color(hex: "#F5F6F8"))
        case .ethernet:            return ("cable.connector", "Ethernet", Color(hex: "#F5F6F8"))
        case .unavailable:         return ("network", "Network", Self.dim)
        }
    }

    private var networkTile: some View {
        let w = wifiLabel
        return StatTile(icon: w.icon, title: w.text, trailing: nil) {
            HStack(spacing: 10) {
                Label(Self.rate(stats.netIn), systemImage: "arrow.down")
                Label(Self.rate(stats.netOut), systemImage: "arrow.up")
                Spacer(minLength: 0)
                Text(stats.ip ?? "No IP")
                    .foregroundColor(stats.ip == nil ? Self.dim : Color(hex: "#60A5FA"))
                    .textSelection(.enabled)
            }
            .font(.system(size: 10.5).monospacedDigit())
            .lineLimit(1)
            #if !APPSTORE
            if stats.wifi == .connected(nil) {
                Button("Show Wi-Fi name…") { stats.requestWiFiName() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundColor(Self.dim)
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: stats.wifi)
    }

    private var bluetoothTile: some View {
        let (icon, title, detail): (String, String, String) = {
            switch stats.bluetooth {
            case .off:               return ("antenna.radiowaves.left.and.right.slash", "Bluetooth off", "")
            case .on:                return ("antenna.radiowaves.left.and.right", "Bluetooth on", "Not connected")
            case .connected(let ns): return ("antenna.radiowaves.left.and.right", "Bluetooth", ns.joined(separator: ", "))
            case .unavailable:       return ("antenna.radiowaves.left.and.right.slash", "Bluetooth", "Unavailable")
            }
        }()
        return StatTile(icon: icon, title: title, trailing: nil) {
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundColor({ if case .connected = stats.bluetooth { return Color(hex: "#60A5FA") }; return Self.dim }())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    static let userColor = Color(hex: "#60A5FA")
    static let systemColor = Color(hex: "#F4505E")
    static let dim = Color(hex: "#8E939C")

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}

private struct StatTile<Content: View>: View {
    let icon: String
    let title: String
    let trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundColor(Color(hex: "#60A5FA"))
                }
            }
            .foregroundColor(Color(hex: "#C5C8CD"))
            content
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }
}

private struct UsedTotal: View {
    let used: Int64
    let total: Int64
    let style: ByteCountFormatter.CountStyle

    var body: some View {
        HStack(spacing: 2) {
            Text(ByteCountFormatter.string(fromByteCount: used, countStyle: style))
                .foregroundColor(Color(hex: "#F5F6F8"))
            Text("/ " + ByteCountFormatter.string(fromByteCount: total, countStyle: style))
                .foregroundColor(StatsView.dim)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(fraction > 0.9 ? Color(hex: "#F4505E") : Color(hex: "#3B82F6"))
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 9.5).monospacedDigit())
        }
    }
}

/// Stacked area chart: user (blue) below, system (red) on top.
private struct CPUSparkline: View {
    let samples: [SystemStats.CPUSample]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                     with: .color(.white.opacity(0.03)))
            guard samples.count > 1 else { return }
            let step = size.width / CGFloat(SystemStats.historyLength - 1)
            let x0 = size.width - step * CGFloat(samples.count - 1)
            func area(_ top: (SystemStats.CPUSample) -> Double) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: x0, y: size.height))
                for (i, s) in samples.enumerated() {
                    p.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: size.height * (1 - CGFloat(min(1, top(s))))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            ctx.fill(area { $0.user + $0.system }, with: .color(StatsView.systemColor.opacity(0.85)))
            ctx.fill(area { $0.user }, with: .color(StatsView.userColor.opacity(0.9)))
        }
    }
}
