import AppKit
import SwiftUI

// MARK: - Advanced stats tab: top processes, memory pressure, swap, history, trend

@MainActor
final class AdvancedStatsStore: ObservableObject {
    static let shared = AdvancedStatsStore()

    struct Proc: Identifiable, Equatable {
        let pid: Int32
        let name: String
        let cpu: Double      // % of one core, as ps and Activity Monitor show it
        let memMB: Double
        var id: Int32 { pid }
    }

    enum Trend: String {
        case normal = "Normal", rising = "Rising", critical = "Critical"
        var color: Color {
            switch self {
            case .normal:   return Color(hex: "#34D399")
            case .rising:   return Color(hex: "#F5A524")
            case .critical: return Color(hex: "#F4505E")
            }
        }
    }

    struct Notice: Equatable {
        var text: String
        var forcePid: Int32? = nil
    }

    static let historyLength = 90          // 3 min at one sample every 2 s
    /// Processes macOS can't live without: never offered a stop button.
    static let protected: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "systemstats",
                                          "logd", "opendirectoryd", "coreaudiod", "hidd", "mds", "configd"]

    @Published private(set) var topCPU: [Proc] = []
    @Published private(set) var topMem: [Proc] = []
    @Published private(set) var cpu: Double = 0             // 0…1, all cores
    @Published private(set) var memUsed: Double = 0         // 0…1
    @Published private(set) var pressure: Int32 = 1         // 1 normal, 2 warning, 4 critical
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var swapTotal: UInt64 = 0
    @Published private(set) var load: Double = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var trend: Trend = .normal
    @Published var notice: Notice?

    private let host = mach_host_self()
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    /// Samples every 2 s until the calling task is cancelled (the tab closes).
    /// ponytail: history only grows while the tab is open (0 % CPU when hidden); a background sampler if gaps matter.
    func run() async {
        while !Task.isCancelled {
            await sample()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func sample() async {
        let procs = await Task.detached { Self.processes() }.value
        topCPU = Array(procs.sorted { $0.cpu > $1.cpu }.prefix(5))
        topMem = Array(procs.sorted { $0.memMB > $1.memMB }.prefix(5))

        if let c = cpuLoad() { cpu = c }
        if let level: Int32 = Self.sysctl("kern.memorystatus_level") { memUsed = 1 - Double(level) / 100 }
        if let p: Int32 = Self.sysctl("kern.memorystatus_vm_pressure_level") { pressure = p }
        if let swap: xsw_usage = Self.sysctl("vm.swapusage") { swapUsed = swap.xsu_used; swapTotal = swap.xsu_total }
        var avg = [Double](repeating: 0, count: 3)
        if getloadavg(&avg, 3) > 0 { load = avg[0] }
        thermal = ProcessInfo.processInfo.thermalState

        cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength))
        memHistory = Array((memHistory + [memUsed]).suffix(Self.historyLength))
        trend = Self.trend(cpu: cpuHistory, mem: memUsed, pressure: pressure, thermal: thermal,
                           swapRatio: swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0)
    }

    /// Critical: the Mac is struggling now. Rising: heading there, or climbing fast.
    nonisolated static func trend(cpu history: [Double], mem: Double, pressure: Int32,
                                  thermal: ProcessInfo.ThermalState, swapRatio: Double) -> Trend {
        func avg(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let recent = avg(history.suffix(5))
        let before = avg(history.dropLast(5).suffix(15))
        if pressure >= 4 || thermal == .serious || thermal == .critical || recent > 0.9 || mem > 0.95 {
            return .critical
        }
        if pressure >= 2 || thermal == .fair || recent > 0.65 || mem > 0.85 || swapRatio > 0.75
            || (history.count >= 10 && recent - before > 0.2) {
            return .rising
        }
        return .normal
    }

    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return nil }
        return Double(busy &- last.busy) / Double(total - last.total)
    }

    nonisolated static func sysctl<T>(_ name: String) -> T? {
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, ptr, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return ptr.pointee
    }

    /// Every process with its CPU % and resident memory, from ps (sees all users, no root needed).
    nonisolated static func processes() -> [Proc] {
        DevToolsStore.run("/bin/ps", ["-A", "-c", "-o", "pid=,%cpu=,rss=,comm="])
            .split(separator: "\n")
            .compactMap { line -> Proc? in
                let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard cols.count == 4, let pid = Int32(cols[0]), pid > 0,
                      let cpu = Double(cols[1].replacingOccurrences(of: ",", with: ".")),
                      let rss = Double(cols[2]) else { return nil }
                return Proc(pid: pid, name: String(cols[3]), cpu: cpu, memMB: rss / 1024)
            }
    }

    // MARK: Actions

    func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    static func canStop(_ p: Proc) -> Bool {
        p.pid > 1 && p.pid != getpid() && !protected.contains(p.name)
    }

    /// Polite stop: apps get a normal Quit (they can ask to save), others SIGTERM. Checks after 3 s.
    func stop(_ p: Proc) {
        guard Self.canStop(p) else {
            notice = Notice(text: "\(p.name) is part of macOS: stopping it would break the system, so Coucou won't.")
            return
        }
        if let app = NSRunningApplication(processIdentifier: p.pid) {
            app.terminate()
        } else if kill(p.pid, SIGTERM) != 0 {
            let e = errno
            notice = Notice(text: e == EPERM
                ? "\(p.name) (PID \(p.pid)) belongs to the system or another user. Stop it from Activity Monitor, which can ask for your password."
                : "Couldn't stop \(p.name) (PID \(p.pid)): \(String(cString: strerror(e))).")
            return
        }
        notice = nil
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard kill(p.pid, 0) == 0 else { await sample(); return }
            notice = Notice(text: "\(p.name) is still running: it may be waiting for you (unsaved work) or ignoring the request.",
                            forcePid: p.pid)
        }
    }

    /// Last resort after a polite stop failed: unsaved work in that app is lost.
    func forceStop(pid: Int32) {
        notice = nil
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.forceTerminate()
        } else if kill(pid, SIGKILL) != 0 {
            notice = Notice(text: "Couldn't force-stop PID \(pid): \(String(cString: strerror(errno))). Try Activity Monitor.")
        }
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); await sample() }
    }
}

// MARK: - View

struct AdvancedStatsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = AdvancedStatsStore.shared

    private var active: Bool { state.mode == .expanded && state.view == .advstats }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            HStack(alignment: .top, spacing: 10) {
                healthColumn.frame(width: 150)
                ProcList(title: "Top CPU", icon: "cpu", procs: store.topCPU, store: store) {
                    String(format: "%.0f%%", $0.cpu)
                }
                ProcList(title: "Top memory", icon: "memorychip", procs: store.topMem, store: store) {
                    $0.memMB >= 1024 ? String(format: "%.1f GB", $0.memMB / 1024) : String(format: "%.0f MB", $0.memMB)
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) {
            if let n = store.notice {
                DevNoticeBar(text: n.text,
                             actionTitle: n.forcePid == nil ? nil : "Force quit",
                             action: n.forcePid.map { pid in { () -> Void in store.forceStop(pid: pid) } }) { store.notice = nil }
                    .padding(.leading, 80).padding(.trailing, 10).padding(.bottom, 8)
            }
        }
        // 0 % CPU when hidden: sampling lives and dies with the tab.
        .task(id: active) {
            if active { await store.run() }
        }
    }

    private var healthColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(store.trend.color).frame(width: 7, height: 7)
                Text(store.trend.rawValue).font(.system(size: 11, weight: .semibold)).foregroundColor(store.trend.color)
                Spacer(minLength: 0)
                Button(action: { store.openActivityMonitor() }) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Open Activity Monitor")
            }
            HistoryChart(cpu: store.cpuHistory, mem: store.memHistory)
                .frame(height: 34)
                .help("Last 3 minutes while this tab is open · blue CPU, purple memory")
            metric("CPU", String(format: "%.0f%%", store.cpu * 100), color: Color(hex: "#60A5FA"))
            metric("Memory", String(format: "%.0f%%", store.memUsed * 100), color: Color(hex: "#C084FC"))
            metric("Pressure", Self.pressureLabel(store.pressure), color: Self.pressureColor(store.pressure))
            metric("Swap", store.swapTotal == 0 ? "off"
                   : ByteCountFormatter.string(fromByteCount: Int64(store.swapUsed), countStyle: .memory), color: nil)
            metric("Load · heat", String(format: "%.2f", store.load) + " · " + Self.thermalLabel(store.thermal),
                   color: store.thermal == .nominal ? nil : Color(hex: "#F5A524"))
        }
    }

    private func metric(_ name: String, _ value: String, color: Color?) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
            Spacer(minLength: 2)
            Text(value).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(color ?? Color(hex: "#E5E7EB"))
                .lineLimit(1)
        }
    }

    static func pressureLabel(_ p: Int32) -> String { p >= 4 ? "critical" : p >= 2 ? "warning" : "normal" }
    static func pressureColor(_ p: Int32) -> Color {
        p >= 4 ? Color(hex: "#F4505E") : p >= 2 ? Color(hex: "#F5A524") : Color(hex: "#34D399")
    }
    static func thermalLabel(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal:  return "cool"
        case .fair:     return "warm"
        case .serious:  return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}

private struct ProcList: View {
    let title: String
    let icon: String
    let procs: [AdvancedStatsStore.Proc]
    @ObservedObject var store: AdvancedStatsStore
    let value: (AdvancedStatsStore.Proc) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Color(hex: "#C5C8CD"))
            if procs.isEmpty {
                Text("Reading…").font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079"))
            }
            ForEach(procs) { ProcRow(proc: $0, value: value($0), store: store) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ProcRow: View {
    let proc: AdvancedStatsStore.Proc
    let value: String
    @ObservedObject var store: AdvancedStatsStore
    @State private var hovered = false

    var body: some View {
        let app = NSRunningApplication(processIdentifier: proc.pid)
        HStack(spacing: 5) {
            if let icon = app?.icon {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            } else {
                Image(systemName: "gearshape").font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")).frame(width: 13)
            }
            Text(app?.localizedName ?? proc.name)
                .font(.system(size: 10.5)).foregroundColor(Color(hex: "#E5E7EB")).lineLimit(1)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(Color(hex: "#C5C8CD"))
            if AdvancedStatsStore.canStop(proc) {
                TwoTapStopButton(label: "Quit", help: "Quit \(app?.localizedName ?? proc.name)") { store.stop(proc) }
                    .opacity(hovered ? 1 : 0.35)
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help("\(proc.name) · PID \(proc.pid)")
    }
}

/// CPU (blue) and memory (purple) over the last samples, 0–100 %.
private struct HistoryChart: View {
    let cpu: [Double]
    let mem: [Double]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.white.opacity(0.04)))
            for (values, hex) in [(mem, "#C084FC"), (cpu, "#60A5FA")] where values.count > 1 {
                let step = size.width / CGFloat(AdvancedStatsStore.historyLength - 1)
                let x0 = size.width - step * CGFloat(values.count - 1)
                var line = Path()
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: x0 + step * CGFloat(i), y: size.height - 2 - CGFloat(min(1, max(0, v))) * (size.height - 4))
                    i == 0 ? line.move(to: pt) : line.addLine(to: pt)
                }
                ctx.stroke(line, with: .color(Color(hex: hex)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
        }
    }
}
