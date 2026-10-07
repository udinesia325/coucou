import CoreAudio
import CoreMediaIO
import SwiftUI

// MARK: - Mic / camera in use + global mic mute

/// Knows when any app uses the microphone or a camera (orange / green dots in the notch,
/// like iOS) and mutes the default input device for every app at once.
/// Event-driven: CoreAudio / CoreMediaIO listeners, no polling.
@MainActor
final class MicCamMonitor: ObservableObject {
    static let shared = MicCamMonitor()

    @Published private(set) var micInUse = false
    @Published private(set) var camInUse = false
    @Published private(set) var micMuted = false

    private var inputDevice = AudioObjectID(kAudioObjectUnknown)
    private var volumeBeforeMute: Float32?

    private init() {
        // Default input device changes (AirPods connect, etc.): follow it.
        var defaultInput = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindInputDevice() }
        }
        bindInputDevice()
        bindCameras()
    }

    // MARK: Microphone

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func bindInputDevice() {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown), device != inputDevice else { return }
        inputDevice = device
        volumeBeforeMute = nil
        for selector in [kAudioDevicePropertyDeviceIsRunningSomewhere] {
            var a = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(device, &a, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshMic() }
            }
        }
        var mute = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        AudioObjectAddPropertyListenerBlock(device, &mute, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshMic() }
        }
        refreshMic()
    }

    private func refreshMic() {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if AudioObjectGetPropertyData(inputDevice, &addr, 0, nil, &size, &running) == noErr {
            micInUse = running != 0
        }
        micMuted = readMute() ?? (volumeBeforeMute != nil)
    }

    private func readMute() -> Bool? {
        var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(inputDevice, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(inputDevice, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    /// Mutes the default input for every app. Devices without a mute switch get volume 0.
    func toggleMicMute() {
        let target = !micMuted
        var mute = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(inputDevice, &mute),
           AudioObjectIsPropertySettable(inputDevice, &mute, &settable) == noErr, settable.boolValue {
            var value: UInt32 = target ? 1 : 0
            AudioObjectSetPropertyData(inputDevice, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else {
            var volume = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput)
            var level: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if target {
                AudioObjectGetPropertyData(inputDevice, &volume, 0, nil, &size, &level)
                volumeBeforeMute = max(level, 0.5)
                level = 0
            } else {
                level = volumeBeforeMute ?? 0.75
                volumeBeforeMute = nil
            }
            AudioObjectSetPropertyData(inputDevice, &volume, 0, nil, size, &level)
            if target { volumeBeforeMute = volumeBeforeMute ?? 0.75 }
        }
        refreshMic()
        micMuted = target
        SoundEngine.shared.play(target ? "close" : "open")
    }

    // MARK: Cameras

    private func bindCameras() {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(0))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return }
        // ponytail: cameras present at launch; one plugged in later is picked up on next launch.
        for device in devices {
            var running = Self.cameraRunningAddress
            CMIOObjectAddPropertyListenerBlock(device, &running, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refreshCameras(devices) }
            }
        }
        refreshCameras(devices)
    }

    private static var cameraRunningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(0))
    }

    private func refreshCameras(_ devices: [CMIOObjectID]) {
        camInUse = devices.contains { device in
            var addr = Self.cameraRunningAddress
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr
                && running != 0
        }
    }
}

/// iOS-style privacy dots for the compact island: orange = mic, green = camera,
/// red slashed mic = muted for every app.
struct PrivacyDots: View {
    @ObservedObject var monitor = MicCamMonitor.shared

    var body: some View {
        VStack(spacing: 3) {
            if monitor.camInUse { Circle().fill(Color(hex: "#34D399")).frame(width: 5, height: 5) }
            if monitor.micMuted {
                Image(systemName: "mic.slash.fill").font(.system(size: 6.5, weight: .bold)).foregroundColor(Color(hex: "#F4505E"))
            } else if monitor.micInUse {
                Circle().fill(Color(hex: "#F5A524")).frame(width: 5, height: 5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: monitor.micInUse)
        .animation(.easeInOut(duration: 0.2), value: monitor.camInUse)
        .animation(.easeInOut(duration: 0.2), value: monitor.micMuted)
        .allowsHitTesting(false)
    }
}
