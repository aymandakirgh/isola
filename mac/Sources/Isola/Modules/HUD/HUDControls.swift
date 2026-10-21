import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

/// The default output device: volume, mute, name/kind, and change listeners.
@MainActor
enum SystemAudio {
    static var device: AudioDeviceID {
        var id = AudioDeviceID(0)
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal, &id)
        return id
    }

    static func volume() -> Double? {
        var v = Float32(0)
        return get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &v) ? Double(v) : nil
    }

    static func canSetVolume() -> Bool {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &a, &settable) == noErr && settable.boolValue
    }

    static func setVolume(_ value: Double) {
        var v = Float32(min(1, max(0, value)))
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    static func isMuted() -> Bool {
        var m = UInt32(0)
        return get(device, kAudioDevicePropertyMute, &m) && m != 0
    }

    static func setMuted(_ muted: Bool) {
        var m = UInt32(muted ? 1 : 0)
        var a = address(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// The device's own scalar → dB curve, falling back to a typical one.
    static func decibels(for scalar: Double) -> Double {
        var v = Float32(scalar)
        if get(device, kAudioDevicePropertyVolumeScalarToDecibels, &v) || get(device, kAudioDevicePropertyVolumeScalarToDecibels, element: 1, &v) {
            return Double(v)
        }
        return HUDOutput.approximateDecibels(scalar)
    }

    static func output() -> HUDOutput {
        let id = device
        var name: Unmanaged<CFString>?
        get(id, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal, &name)
        var model: Unmanaged<CFString>?
        get(id, kAudioDevicePropertyModelUID, scope: kAudioObjectPropertyScopeGlobal, &model)
        var transport = UInt32(0)
        get(id, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, &transport)
        var source = UInt32(0)
        let hasSource = get(id, kAudioDevicePropertyDataSource, &source)
        let deviceName = name?.takeRetainedValue() as String? ?? "Speakers"
        // CoreAudio names a Bluetooth output after the device the Bluetooth monitor tracks.
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let known = bluetooth ? DevicesState.shared.devices.first { $0.name == deviceName } : nil
        return HUDOutput(
            name: deviceName, transport: transport, dataSource: hasSource ? source : nil,
            deviceSymbol: known?.symbol, deviceTint: known?.tint, model: model?.takeRetainedValue() as String?
        )
    }

    // MARK: Listeners

    private static var observed: AudioDeviceID = 0
    private static var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Calls `onChange` on the main queue whenever volume or mute changes on the current
    /// output device; follows default-device switches.
    static func observe(_ onChange: @escaping @MainActor () -> Void) {
        let deviceChanged: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { attach(onChange) }
        }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, deviceChanged)
        attach(onChange)
    }

    private static func attach(_ onChange: @escaping @MainActor () -> Void) {
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, .main, block)
        }
        listeners.removeAll()
        observed = device
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        // Devices expose volume on the virtual main control, the main element, or per channel.
        let addresses = [
            address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
            address(kAudioDevicePropertyVolumeScalar),
            address(kAudioDevicePropertyVolumeScalar, element: 1),
            address(kAudioDevicePropertyVolumeScalar, element: 2),
            address(kAudioDevicePropertyMute),
        ]
        for var a in addresses where AudioObjectHasProperty(observed, &a) {
            if AudioObjectAddPropertyListenerBlock(observed, &a, .main, block) == noErr {
                listeners.append((observed, a, block))
            }
        }
    }

    // MARK: Plumbing

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    @discardableResult
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput, element: UInt32 = kAudioObjectPropertyElementMain, _ value: inout T) -> Bool {
        var a = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(object, &a) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) } == noErr
    }
}

/// Built-in (and Apple) display brightness through the private DisplayServices framework.
@MainActor
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn = symbol("DisplayServicesGetBrightness", as: GetFn.self)
    private static let setFn = symbol("DisplayServicesSetBrightness", as: SetFn.self)
    private static let canFn = symbol("DisplayServicesCanChangeBrightness", as: CanFn.self)

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let lib, let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func canChange(_ id: CGDirectDisplayID) -> Bool { canFn?(id) ?? false }

    static func get(_ id: CGDirectDisplayID) -> Double? {
        var v = Float(0)
        guard let getFn, getFn(id, &v) == 0 else { return nil }
        return Double(v)
    }

    static func set(_ id: CGDirectDisplayID, _ value: Double) {
        _ = setFn?(id, Float(min(1, max(0, value))))
    }

    /// The display the brightness keys drive: the built-in one first, or with Control
    /// (the macOS convention for external displays) the next adjustable display.
    static func target(alternate: Bool) -> NSScreen? {
        let adjustable = NSScreen.screens.filter { canChange($0.displayID) }
        let ordered = adjustable.sorted { $0.isBuiltIn && !$1.isBuiltIn }
        return alternate ? ordered.dropFirst().first ?? ordered.first : ordered.first
    }
}

/// BetterDisplay's documented feed for third-party HUDs: with its Settings › Application ›
/// Integration › "Dispatch OSD notifications" on, each brightness or volume change on a
/// display it drives (DDC monitors included) is posted as a distributed notification whose
/// object is this JSON. https://betterdisplay.pro/guide/integration/third-party-apps/
struct BetterDisplayOSD: Decodable {
    /// The current name; the legacy com.betterdisplay one repeats every event.
    static let notification = Notification.Name("pro.betterdisplay.BetterDisplay.osd")

    var displayID: Int?
    var systemIconID: Int?  // 1 brightness, 3 volume, 4 mute
    var controlTarget: String?  // combinedBrightness, hardwareBrightness, softwareBrightness, volume, mute, …
    var value: Double?
    var maxValue: Double?

    /// The HUD it maps to; nil for what Isola has no HUD for (contrast, gamma, …) or a
    /// level it can't place (no maximum).
    @MainActor func snapshot() -> HUDSnapshot? {
        let target = controlTarget ?? ""
        let fraction = value.flatMap { v in maxValue.flatMap { $0 > 0 ? min(1, max(0, v / $0)) : nil } }
        let screen = NSScreen.screens.first { Int($0.displayID) == displayID }
        let name = screen.map { $0.isBuiltIn ? "Built-in Display" : $0.localizedName } ?? "Display"
        if target.hasSuffix("Brightness") || (target.isEmpty && systemIconID == 1) {
            return fraction.map { HUDSnapshot(kind: .brightness, level: $0, displayName: name) }
        }
        let muted = target == "mute" || (target.isEmpty && systemIconID == 4)
        guard muted || target == "volume" || (target.isEmpty && systemIconID == 3), muted || fraction != nil else { return nil }
        let level = fraction ?? 0
        return HUDSnapshot(
            kind: .volume, level: level, muted: muted, decibels: HUDOutput.approximateDecibels(level),
            output: HUDOutput(name: name, transport: kAudioDeviceTransportTypeDisplayPort)
        )
    }
}

enum MediaKey: Int {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
}

/// Optional session event tap that takes over the volume/brightness keys so Isola's
/// HUD replaces the macOS one. Needs Accessibility; never installed without it.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { tap != nil }

    func install() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: nil) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func remove() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyTap.shared.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Aux control buttons (subtype 8): key code in the high word, state in the low word.
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
        let key = MediaKey(rawValue: (ns.data1 & 0xFFFF_0000) >> 16)
    else { return Unmanaged.passUnretained(event) }
    let flags = ns.data1 & 0xFFFF
    let down = (flags & 0xFF00) >> 8 == 0xA
    let mods = ns.modifierFlags
    // Option alone opens the matching System Settings pane: leave that to macOS.
    if mods.contains(.option), !mods.contains(.shift) { return Unmanaged.passUnretained(event) }
    let handled = MainActor.assumeIsolated {
        HUDModule.handle(key, down: down, fine: mods.contains(.option) && mods.contains(.shift), alternate: mods.contains(.control), shift: mods.contains(.shift))
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}
