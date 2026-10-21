import AppKit
import ApplicationServices
import CoreBluetooth
import CoreServices
import EventKit
import Intents
import Observation
import SwiftUI

enum PermissionStatus { case granted, denied, notDetermined }

/// Permissions Isola can use. Status checks never prompt; `request()` runs only on a button press.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, calendar, bluetooth, automation, focus, fullDiskAccess
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .bluetooth: "Bluetooth"
        case .automation: "Music & Spotify"
        case .focus: "Focus Status"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Replace the volume and brightness HUDs with the island."
        case .calendar: "Show upcoming events and time-to-leave alerts."
        case .bluetooth: "Announce headphones as they connect, with battery."
        case .automation: "Read and control the track playing in Music and Spotify."
        case .focus: "Show when a Focus turns on or off."
        case .fullDiskAccess: "Name the Focus that’s on, custom ones too. Isola only reads the Focus database."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .calendar: "calendar"
        case .bluetooth: "airpodspro"
        case .automation: "music.note"
        case .focus: "moon.fill"
        case .fullDiskAccess: "internaldrive.fill"
        }
    }

    var tint: Color {
        switch self {
        case .accessibility: .blue
        case .calendar: .red
        case .bluetooth: .indigo
        case .automation: .pink
        case .focus: .purple
        case .fullDiskAccess: .gray
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
        case .bluetooth: "Privacy_Bluetooth"
        case .automation: "Privacy_Automation"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .focus: ""  // see openSystemSettings()
        }
    }

    @MainActor func status() -> PermissionStatus {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .automation:
            switch Self.automationStatus(ask: false) {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            default: return .notDetermined
            }
        case .focus:
            switch INFocusStatusCenter.default.authorizationStatus {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .fullDiskAccess:
            // Nothing to ask for: it is granted by hand in System Settings.
            return FocusMonitor.canReadDatabase ? .granted : .denied
        }
    }

    @MainActor func request(_ done: @escaping () -> Void) {
        switch self {
        case .accessibility:
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            done()
        case .calendar:
            EKEventStore().requestFullAccessToEvents { _, _ in DispatchQueue.main.async(execute: done) }
        case .bluetooth:
            // Creating a central manager is what triggers the Bluetooth prompt.
            BluetoothPrompt.shared.trigger(done)
        case .automation:
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty,
               let music = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                NSWorkspace.shared.openApplication(at: music, configuration: .init())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                _ = Self.automationStatus(ask: true)
                DispatchQueue.main.async(execute: done)
            }
        case .focus:
            INFocusStatusCenter.default.requestAuthorization { _ in DispatchQueue.main.async(execute: done) }
        case .fullDiskAccess:
            openSystemSettings()
            done()
        }
    }

    func openSystemSettings() {
        // Sharing Focus status is managed in Focus settings, not Privacy & Security.
        let url = self == .focus ? FocusMonitor.settingsURL : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
        if let url { NSWorkspace.shared.open(url) }
    }

    private nonisolated static func automationStatus(ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = "com.apple.Music"
        let created = id.withCString { AECreateDesc(typeApplicationBundleID, $0, id.utf8.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }
}

/// Keeps the CBCentralManager alive while macOS shows the Bluetooth prompt.
final class BluetoothPrompt: NSObject, CBCentralManagerDelegate {
    @MainActor static let shared = BluetoothPrompt()
    private var manager: CBCentralManager?
    private var done: (() -> Void)?

    @MainActor func trigger(_ done: @escaping () -> Void) {
        self.done = done
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            done?()
            done = nil
        }
    }
}

@MainActor @Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, permissions, done }
    var step: Step = .welcome
    var statuses: [Permission: PermissionStatus] = [:]
    var onFinish: () -> Void = {}

    func refresh() {
        let fresh = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.status()) })
        if fresh != statuses { statuses = fresh }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        onFinish()
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .permissions: permissions
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            footer
        }
        .frame(width: 560, height: 560)
        .animation(.interpolatingSpring(mass: 1, stiffness: 190, damping: 22), value: model.step)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcon.image).resizable().frame(width: 128, height: 128)
            VStack(spacing: 6) {
                Text("Welcome to Isola").font(.system(size: 30, weight: .bold))
                Text("Dynamic Island, now for your Mac.").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                tip("hand.point.up.left.fill", "Hover to peek")
                tip("cursorarrow.click", "Click to expand")
                tip("hand.draw.fill", "Swipe to skip")
            }
            .padding(.top, 8)
        }
        .padding(.top, 20)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make the most of Isola").font(.system(size: 24, weight: .bold))
                Text("Each permission is optional — grant only the features you want.").foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { i, permission in
                    if i > 0 { Divider().padding(.leading, 56) }
                    permissionRow(permission)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            // Grants made in System Settings (Accessibility, Full Disk Access) show up on their own.
            guard !SystemModule.renderingGallery else { return }
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        let status = model.statuses[permission] ?? .notDetermined
        return HStack(spacing: 12) {
            SidebarIcon(symbol: permission.symbol, tint: permission.tint).scaleEffect(1.3).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).fontWeight(.semibold)
                Text(permission.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            case .denied:
                Button("Open Settings") { permission.openSystemSettings() }
            case .notDetermined:
                Button("Allow") { permission.request { model.refresh() } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("You’re all set").font(.system(size: 28, weight: .bold))
            Text("Isola lives at the top of your screen. Find settings, a timer\nand media controls in the menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                    Circle()
                        .fill(step == model.step ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.step = OnboardingModel.Step(rawValue: model.step.rawValue - 1) ?? .welcome }
            }
            Button(model.step == .done ? "Start Using Isola" : "Continue") {
                if model.step == .done { model.finish() } else {
                    model.step = OnboardingModel.Step(rawValue: model.step.rawValue + 1) ?? .done
                    if model.step == .permissions { model.refresh() }
                }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        let model = OnboardingModel()
        window?.close()
        let w = makeWindow(model: model)
        model.onFinish = { w.close() }
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    static func makeWindow(model: OnboardingModel) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.contentView = NSHostingView(rootView: OnboardingView(model: model))
        return w
    }
}
