#if !APPSTORE
import AppKit
import CoreLocation
import EventKit
import IOKit.ps
import SwiftUI

// MARK: - Shared AppleScript runner

enum AppleScriptRunner {
    struct Outcome: Sendable { let values: [String]; let error: String? }
    private static let queue = DispatchQueue(label: "fr.louisraille.coucou.applescript")

    static func run(_ source: String) async -> Outcome {
        await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                guard let desc = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
                    cont.resume(returning: Outcome(values: [], error: error?[NSAppleScript.errorMessage] as? String ?? "AppleScript error"))
                    return
                }
                let values = desc.numberOfItems > 0
                    ? (1...desc.numberOfItems).map { desc.atIndex($0)?.stringValue ?? "" }
                    : [desc.stringValue ?? ""]
                cont.resume(returning: Outcome(values: values, error: nil))
            }
        }
    }
}

@MainActor
private func peekAndReact(_ emote: BotEmote, sound: String) {
    if AppState.shared.mode == .hidden { NotificationCenter.default.post(name: .musicReveal, object: nil) }
    NotificationCenter.default.post(name: .triggerEmote, object: emote)
    SoundEngine.shared.play(sound)
}

// MARK: - Focus timer (Pomodoro)

@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()
    enum Phase { case idle, focus, rest }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var endDate: Date?
    @Published var focusMinutes: Int = UserDefaults.standard.object(forKey: "focusMinutes") as? Int ?? 25 {
        didSet { UserDefaults.standard.set(focusMinutes, forKey: "focusMinutes") }
    }
    private var timer: Task<Void, Never>?

    var restMinutes: Int { focusMinutes >= 50 ? 10 : 5 }

    func remaining(at date: Date = Date()) -> TimeInterval {
        max(0, (endDate ?? date).timeIntervalSince(date))
    }

    func startFocus() { begin(.focus, minutes: focusMinutes) }

    func stop() {
        timer?.cancel()
        phase = .idle
        endDate = nil
        AppState.shared.focusRunning = false
        if AppState.shared.stateOverride == .sleeping { AppState.shared.stateOverride = nil }
    }

    func skip() { phase == .focus ? phaseEnded() : stop() }

    private func begin(_ next: Phase, minutes: Int) {
        timer?.cancel()
        phase = next
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        AppState.shared.focusRunning = true
        // Mochi naps during the break.
        if next == .rest {
            AppState.shared.stateOverride = .sleeping
        } else if AppState.shared.stateOverride == .sleeping {
            AppState.shared.stateOverride = nil
        }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.phaseEnded()
        }
    }

    private func phaseEnded() {
        if phase == .focus {
            peekAndReact(.proud, sound: "finish")
            begin(.rest, minutes: restMinutes)
        } else {
            stop()
            peekAndReact(.happy, sound: "greet")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Calendar (next meeting)

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let color: Color?
        let joinURL: URL?
    }

    @Published private(set) var granted = false
    @Published private(set) var denied = false
    @Published private(set) var next: Event?
    private let store = EKEventStore()
    private var alarm: Task<Void, Never>?
    private var observer: Any?

    private init() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) {
            granted = status == .fullAccess || status == .authorized
        } else {
            granted = status == .authorized
        }
        denied = status == .denied || status == .restricted
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func requestAccess() {
        if denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let done: @Sendable (Bool, Error?) -> Void = { ok, _ in
            Task { @MainActor in
                CalendarStore.shared.granted = ok
                CalendarStore.shared.denied = !ok
                CalendarStore.shared.refresh()
            }
        }
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
    }

    func refresh() {
        guard granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(86_400), calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .min { $0.startDate < $1.startDate }
        next = event.map {
            Event(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                  color: $0.calendar.map { Color(nsColor: $0.color) },
                  joinURL: Self.joinURL(in: [$0.url?.absoluteString, $0.location, $0.notes]))
        }
        scheduleAlarm()
    }

    /// One minute before the meeting Mochi peeks out; when it ends, look for the next one.
    private func scheduleAlarm() {
        alarm?.cancel()
        guard let next else { return }
        alarm = Task { [weak self] in
            let warn = next.start.addingTimeInterval(-60).timeIntervalSinceNow
            if warn > 0 {
                try? await Task.sleep(nanoseconds: UInt64(warn * 1_000_000_000))
                guard !Task.isCancelled else { return }
                peekAndReact(.surprised, sound: "question")
            }
            let untilEnd = next.end.timeIntervalSinceNow
            if untilEnd > 0 { try? await Task.sleep(nanoseconds: UInt64(untilEnd * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    static func joinURL(in texts: [String?]) -> URL? {
        let pattern = #"https?://[^\s<>"]*(zoom\.us/(j|my)/|meet\.google\.com/|teams\.microsoft\.com/|teams\.live\.com/|webex\.com/)[^\s<>"]*"#
        for text in texts.compactMap({ $0 }) {
            if let r = text.range(of: pattern, options: .regularExpression), let url = URL(string: String(text[r])) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Weather (Open-Meteo, location from CoreLocation)

@MainActor
final class WeatherStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherStore()

    @Published private(set) var temperature: Double?
    @Published private(set) var high: Double?
    @Published private(set) var low: Double?
    @Published private(set) var code: Int?
    @Published private(set) var isDay = true
    @Published private(set) var city: String?
    @Published private(set) var needsPermission = false
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastFetch: Date?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refreshIfStale() {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 900 { return }
        switch manager.authorizationStatus {
        case .notDetermined, .denied, .restricted: needsPermission = true
        default:
            needsPermission = false
            manager.requestLocation()
        }
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        let lat = c.latitude, lon = c.longitude
        Task { @MainActor in await self.fetch(lat: lat, lon: lon) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.lastFetch = nil
            self.refreshIfStale()
        }
    }

    private func fetch(lat: Double, lon: Double) async {
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else { return }
        lastFetch = Date()
        temperature = current["temperature_2m"] as? Double
        code = current["weather_code"] as? Int
        isDay = (current["is_day"] as? Int ?? 1) == 1
        let daily = json["daily"] as? [String: Any]
        high = (daily?["temperature_2m_max"] as? [Double])?.first
        low = (daily?["temperature_2m_min"] as? [Double])?.first
        geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { [weak self] places, _ in
            let name = places?.first?.locality
            Task { @MainActor [weak self] in self?.city = name }
        }
    }

    var symbol: String {
        switch code ?? -1 {
        case 0:            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:         return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51...57:      return "cloud.drizzle.fill"
        case 65, 67, 82:   return "cloud.heavyrain.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86:  return "cloud.snow.fill"
        case 95...99:      return "cloud.bolt.rain.fill"
        default:           return "cloud.sun"
        }
    }
}

// MARK: - Battery (Mac + Bluetooth devices such as AirPods)

@MainActor
final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    struct Device: Identifiable {
        let name: String
        let levels: [(label: String, percent: Int)]
        var id: String { name }
    }

    @Published private(set) var percent: Int?
    @Published private(set) var charging = false
    @Published private(set) var onAC = false
    @Published private(set) var minutesLeft: Int?
    @Published private(set) var devices: [Device] = []
    private var warnedLow = false

    private init() {
        refresh()
        // Power events (plug, unplug, percent change) instead of polling.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerStore.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : nil
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let t = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            minutesLeft = t > 0 ? t : nil
        }
        // Low battery: Mochi yawns once per discharge.
        if onAC { warnedLow = false }
        if let percent, percent <= 20, !onAC, !warnedLow {
            warnedLow = true
            peekAndReact(.yawn, sound: "sleep")
        }
    }

    func refreshDevices() {
        Task {
            devices = await Task.detached { Self.bluetoothBatteries() }.value
        }
    }

    /// Connected Bluetooth devices with a battery, from system_profiler (AirPods: left/right/case).
    nonisolated static func bluetoothBatteries() -> [Device] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else { return [] }
        let keys = [("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"),
                    ("device_batteryLevelCase", "Case"), ("device_batteryLevelMain", "")]
        return connected.compactMap { entry in
            guard let (name, value) = entry.first, let info = value as? [String: Any] else { return nil }
            let levels = keys.compactMap { (key, label) -> (label: String, percent: Int)? in
                guard let s = info[key] as? String, let n = Int(s.replacingOccurrences(of: "%", with: "")) else { return nil }
                return (label, n)
            }
            return levels.isEmpty ? nil : Device(name: name, levels: levels)
        }
    }
}

// MARK: - Meeting controls (Zoom menu, Google Meet in Chrome)

@MainActor
final class MeetingControls: ObservableObject {
    static let shared = MeetingControls()

    @Published private(set) var zoomRunning = false
    @Published private(set) var chromeRunning = false
    /// nil when Zoom has no meeting menu (not in a meeting).
    @Published private(set) var zoomAudioOn: Bool?
    @Published private(set) var zoomVideoOn: Bool?
    @Published private(set) var needsAccessibility = false

    private static func running(_ id: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
    }

    func refresh() {
        zoomRunning = Self.running("us.zoom.xos")
        chromeRunning = Self.running("com.google.Chrome")
        guard zoomRunning else { zoomAudioOn = nil; zoomVideoOn = nil; return }
        Task {
            let r = await AppleScriptRunner.run("""
                tell application "System Events" to tell process "zoom.us"
                    set m to menu 1 of menu bar item "Meeting" of menu bar 1
                    set a to "none"
                    set v to "none"
                    if exists menu item "Mute Audio" of m then set a to "on"
                    if exists menu item "Unmute Audio" of m then set a to "off"
                    if exists menu item "Stop Video" of m then set v to "on"
                    if exists menu item "Start Video" of m then set v to "off"
                    return {a, v}
                end tell
                """)
            handle(r)
            zoomAudioOn = r.values.first.flatMap { $0 == "none" ? nil : $0 == "on" }
            zoomVideoOn = r.values.dropFirst().first.flatMap { $0 == "none" ? nil : $0 == "on" }
        }
    }

    private func handle(_ r: AppleScriptRunner.Outcome) {
        // UI scripting needs Accessibility; other errors just mean "not in a meeting".
        needsAccessibility = r.error?.localizedCaseInsensitiveContains("assistive") == true
            || r.error?.localizedCaseInsensitiveContains("not allowed") == true
    }

    func zoomToggle(video: Bool) {
        let (on, off) = video ? ("Stop Video", "Start Video") : ("Mute Audio", "Unmute Audio")
        Task {
            let r = await AppleScriptRunner.run("""
                tell application "System Events" to tell process "zoom.us"
                    set m to menu 1 of menu bar item "Meeting" of menu bar 1
                    if exists menu item "\(on)" of m then
                        click menu item "\(on)" of m
                    else
                        click menu item "\(off)" of m
                    end if
                end tell
                """)
            handle(r)
            refresh()
        }
    }

    /// Google Meet has no API: bring its Chrome tab forward, send ⌘D (mic) / ⌘E (camera),
    /// then hand focus back to the app you were in.
    func meetToggle(camera: Bool) {
        let previous = NSWorkspace.shared.frontmostApplication
        Task {
            let r = await AppleScriptRunner.run("""
                tell application "Google Chrome"
                    set found to false
                    repeat with w in windows
                        set i to 0
                        repeat with t in tabs of w
                            set i to i + 1
                            if URL of t contains "meet.google.com/" then
                                set active tab index of w to i
                                set index of w to 1
                                set found to true
                                exit repeat
                            end if
                        end repeat
                        if found then exit repeat
                    end repeat
                    if not found then return "none"
                    activate
                end tell
                delay 0.3
                tell application "System Events" to keystroke "\(camera ? "e" : "d")" using command down
                return "ok"
                """)
            handle(r)
            if r.values.first == "none" { SoundEngine.shared.play("error") }
            try? await Task.sleep(nanoseconds: 350_000_000)
            previous?.activate(options: [])
        }
    }

    func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

// MARK: - Today view

struct TodayView: View {
    @ObservedObject var state: AppState
    @ObservedObject var calendar = CalendarStore.shared
    @ObservedObject var weather = WeatherStore.shared
    @ObservedObject var focus = FocusTimer.shared
    @ObservedObject var power = PowerStore.shared
    @ObservedObject var meeting = MeetingControls.shared
    @ObservedObject var mic = MicCamMonitor.shared

    private var active: Bool { state.mode == .expanded && state.view == .today }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    calendarTile.frame(width: 230)
                    weatherTile
                    batteryTile
                }
                HStack(spacing: 6) {
                    focusTile.frame(width: 230)
                    meetingTile
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .task(id: active) {
            guard active else { return }
            calendar.refresh()
            weather.refreshIfStale()
            while !Task.isCancelled {
                power.refreshDevices()
                meeting.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // Calendar

    private var calendarTile: some View {
        TodayTile(icon: "calendar", title: "Next meeting") {
            if !calendar.granted {
                tileButton(calendar.denied ? "Allow in System Settings" : "Show my calendar") { calendar.requestAccess() }
            } else if let e = calendar.next {
                HStack(spacing: 5) {
                    Circle().fill(e.color ?? .blue).frame(width: 6, height: 6)
                    Text(e.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: active ? 30 : 3600)) { ctx in
                    Text(Self.when(e, now: ctx.date)).font(.system(size: 10)).foregroundColor(Self.dim)
                }
                if let url = e.joinURL {
                    tileButton("Join", icon: "video.fill") { NSWorkspace.shared.open(url) }
                }
            } else {
                Text("No more meetings in the next 24 h").font(.system(size: 10.5)).foregroundColor(Self.dim)
            }
        }
    }

    static func when(_ e: CalendarStore.Event, now: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        let range = "\(f.string(from: e.start))–\(f.string(from: e.end))"
        let minutes = Int(e.start.timeIntervalSince(now) / 60)
        if e.start <= now { return "Now · until \(f.string(from: e.end))" }
        if minutes < 60 { return "In \(max(1, minutes)) min · \(range)" }
        return range
    }

    // Weather

    private var weatherTile: some View {
        TodayTile(icon: weather.symbol, title: weather.city ?? "Weather") {
            if weather.needsPermission {
                tileButton("Allow location") { weather.requestPermission() }
            } else if let t = weather.temperature {
                Text("\(Int(t.rounded()))°").font(.system(size: 20, weight: .semibold))
                if let h = weather.high, let l = weather.low {
                    Text("H \(Int(h.rounded()))°  L \(Int(l.rounded()))°").font(.system(size: 10)).foregroundColor(Self.dim)
                }
            } else {
                Text("Loading…").font(.system(size: 10.5)).foregroundColor(Self.dim)
            }
        }
    }

    // Battery

    private var batteryTile: some View {
        TodayTile(icon: power.charging ? "battery.100.bolt" : "battery.75", title: "Battery") {
            if let p = power.percent {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(p)%").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(p <= 20 && !power.onAC ? Color(hex: "#F4505E") : Color(hex: "#F5F6F8"))
                    if let m = power.minutesLeft, !power.onAC {
                        Text("\(m / 60)h\(String(format: "%02d", m % 60))").font(.system(size: 9.5)).foregroundColor(Self.dim)
                    }
                }
            }
            ForEach(power.devices.prefix(2)) { d in
                Text("\(d.name): " + d.levels.map { "\($0.label) \($0.percent)%".trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
                    .font(.system(size: 9.5)).foregroundColor(Color(hex: "#60A5FA")).lineLimit(1)
            }
        }
    }

    // Focus

    private var focusTile: some View {
        TodayTile(icon: focus.phase == .rest ? "cup.and.saucer.fill" : "timer", title: focus.phase == .rest ? "Break" : "Focus") {
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: active && focus.phase != .idle ? 1 : 3600)) { ctx in
                    Text(focus.phase == .idle ? "\(focus.focusMinutes):00" : FocusTimer.clock(focus.remaining(at: ctx.date)))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundColor(focus.phase == .rest ? Color(hex: "#60A5FA") : Color(hex: "#F5F6F8"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if focus.phase == .idle {
                        tileButton("Start", icon: "play.fill") { focus.startFocus() }
                        HStack(spacing: 4) {
                            ForEach([25, 50], id: \.self) { m in
                                Button("\(m)m") { focus.focusMinutes = m }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9.5, weight: focus.focusMinutes == m ? .bold : .regular))
                                    .foregroundColor(focus.focusMinutes == m ? Color(hex: "#F5F6F8") : Self.dim)
                            }
                        }
                    } else {
                        tileButton("Skip", icon: "forward.end.fill") { focus.skip() }
                        tileButton("Stop", icon: "stop.fill") { focus.stop() }
                    }
                }
            }
        }
    }

    // Meeting

    private var meetingTile: some View {
        TodayTile(icon: "person.2.wave.2.fill", title: "Meeting") {
            HStack(spacing: 6) {
                PillToggleButton(on: mic.micMuted, icon: mic.micMuted ? "mic.slash.fill" : "mic.fill",
                                 label: mic.micMuted ? "Mic muted" : "Mic") { mic.toggleMicMute() }
                if meeting.zoomRunning, meeting.zoomAudioOn != nil || meeting.zoomVideoOn != nil {
                    PillToggleButton(on: meeting.zoomAudioOn == false, icon: "z.circle.fill",
                                     label: meeting.zoomAudioOn == false ? "Zoom unmute" : "Zoom mute") { meeting.zoomToggle(video: false) }
                    PillToggleButton(on: meeting.zoomVideoOn == false, icon: meeting.zoomVideoOn == false ? "video.slash.fill" : "video.fill",
                                     label: "Zoom cam") { meeting.zoomToggle(video: true) }
                }
            }
            HStack(spacing: 6) {
                if meeting.chromeRunning {
                    Text("Meet").font(.system(size: 10, weight: .semibold)).foregroundColor(Self.dim)
                    PillToggleButton(on: false, icon: "mic", label: "⌘D") { meeting.meetToggle(camera: false) }
                    PillToggleButton(on: false, icon: "video", label: "⌘E") { meeting.meetToggle(camera: true) }
                }
                if meeting.needsAccessibility {
                    tileButton("Allow Accessibility") { meeting.openAccessibilitySettings() }
                }
            }
        }
    }

    // Helpers

    static let dim = Color(hex: "#8E939C")

    private func tileButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9)) }
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
    }
}

private struct TodayTile<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
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

// MARK: - Compact notch: focus countdown (screens without a notch, when no lyric is showing)

struct CompactFocusClock: View {
    @ObservedObject var focus = FocusTimer.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 3) {
                Image(systemName: focus.phase == .rest ? "cup.and.saucer.fill" : "timer").font(.system(size: 8))
                Text(FocusTimer.clock(focus.remaining(at: ctx.date))).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(focus.phase == .rest ? Color(hex: "#60A5FA") : Color(hex: "#F5A524"))
        }
        .allowsHitTesting(false)
    }
}
#endif
