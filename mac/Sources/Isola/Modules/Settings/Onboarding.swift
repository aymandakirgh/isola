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
    case accessibility, calendar, bluetooth, automation, browser, focus, fullDiskAccess
    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .bluetooth: "Bluetooth"
        case .automation: "Music & Spotify"
        case .browser: "Browsers"
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
        case .browser: "Find and bring forward the tab that’s playing."
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
        case .browser: "globe"
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
        case .browser: .teal
        case .focus: .purple
        case .fullDiskAccess: .gray
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
        case .bluetooth: "Privacy_Bluetooth"
        case .automation, .browser: "Privacy_Automation"
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
        case .automation, .browser:
            switch Self.automationStatus(of: automationTarget, ask: false) {
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
        case .automation, .browser:
            // macOS only asks about an app that is running.
            let target = automationTarget
            if NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty,
               let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                _ = Self.automationStatus(of: target, ask: true)
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

    /// The app an Automation permission is asked about: Music, or for Browsers the scriptable
    /// browser that's running, else the default browser if it's scriptable, else Safari.
    @MainActor private var automationTarget: String {
        guard self == .browser else { return "com.apple.Music" }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let id = running.first(where: { Browser(bundleID: $0) != nil }) { return id }
        if let web = URL(string: "https://example.com"), let app = NSWorkspace.shared.urlForApplication(toOpen: web),
           let id = Bundle(url: app)?.bundleIdentifier, Browser(bundleID: id) != nil {
            return id
        }
        return "com.apple.Safari"
    }

    private nonisolated static func automationStatus(of id: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
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
            SystemModule.startBluetoothIfAllowed()
        }
    }
}

@MainActor @Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, permissions, license, done }
    var step: Step = .welcome
    var statuses: [Permission: PermissionStatus] = [:]
    /// Permissions whose system prompt is up: their button reads "Waiting…".
    var pending: Set<Permission> = []
    /// The license step shows its key field.
    var showKey = false
    /// A Mac that is licensed when onboarding opens skips the license step.
    let skipsLicense: Bool
    var onFinish: () -> Void = {}

    init(skipsLicense: Bool? = nil) {
        self.skipsLicense = skipsLicense ?? (License.shared.status == .licensed)
    }

    var steps: [Step] { Step.allCases.filter { $0 != .license || !skipsLicense } }

    func advance() {
        guard let i = steps.firstIndex(of: step), i + 1 < steps.count else { return }
        step = steps[i + 1]
        if step == .permissions { refresh() }
    }

    func back() {
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        step = steps[i - 1]
    }

    func request(_ permission: Permission) {
        pending.insert(permission)
        permission.request { [weak self] in
            self?.pending.remove(permission)
            self?.refresh()
        }
    }

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
    @Bindable var license = License.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: welcome
                case .permissions: permissions
                case .license: licenseStep
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            footer
        }
        .frame(width: 560, height: 620)
        .animation(.interpolatingSpring(mass: 1, stiffness: 190, damping: 22), value: model.step)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcon.image).resizable().frame(width: 128, height: 128)
            VStack(spacing: 6) {
                Text("Welcome to Isola").font(.system(size: 30, weight: .bold))
                Text("Dynamic Island, now for your Mac.").font(.title3).foregroundStyle(.secondary)
                Text("Notifications, alerts and live activities, right in your notch.").foregroundStyle(.secondary).padding(.top, 2)
            }
            HStack(alignment: .top, spacing: 14) {
                tip("hand.point.up.left.fill", "Hover to peek")
                tip("cursorarrow.click", "Click to expand")
                tip("hand.draw.fill", "Swipe to skip")
                tip("arrow.up.arrow.down", "Swipe down to open, up to close")
            }
            .padding(.top, 8)
        }
        .padding(.top, 20)
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(height: 24)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 110)
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
            Text("When macOS asks, choose Allow (or Open for System Settings).").font(.callout).foregroundStyle(.secondary)
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
                let waiting = model.pending.contains(permission)
                Button(waiting ? "Waiting…" : "Allow") { model.request(permission) }
                    .disabled(waiting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder private var licenseStep: some View {
        if license.status == .licensed {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
                Text("Your license is active").font(.system(size: 28, weight: .bold))
                // This Mac is on the license whatever the list says.
                Text("\(max(1, license.devices.count)) of \(License.deviceLimit) Macs used").foregroundStyle(.secondary)
            }
        } else {
            let expired = license.status == .expired
            VStack(spacing: 16) {
                SidebarIcon(symbol: "key.fill", tint: .orange).scaleEffect(2.4).frame(width: 60, height: 60)
                VStack(spacing: 6) {
                    Text("Activate Isola").font(.system(size: 28, weight: .bold))
                    Text(expired ? "Your 72-hour trial has ended. Isola keeps working; a license supports it." : "Start the 72-hour trial or activate your license to continue.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button(expired ? "Not Now" : "Start Trial") { model.advance() }
                        .glassButton(prominent: !model.showKey)
                    Button("Buy Isola…") { NSWorkspace.shared.open(License.website) }
                        .glassButton()
                    if !model.showKey {
                        Button("Activate License") { model.showKey = true }
                            .glassButton()
                    }
                }
                if model.showKey { keyField }
                VStack(spacing: 3) {
                    Group {
                        Text("Activate on up to \(License.deviceLimit) Macs.")
                        Text("The trial lasts 72 hours.")
                    }
                    .foregroundStyle(.secondary)
                    Link("Lost your license?", destination: License.website.appendingPathComponent("recover"))
                }
                .font(.callout)
                .padding(.top, 4)
            }
            .padding(.horizontal, 40)
        }
    }

    private var keyField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("License key", text: $license.draft, prompt: Text("ISOLA-XXXX-XXXX-XXXX"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 240)
                    .onSubmit { license.activate(license.draft) }
                Button("Activate License") { license.activate(license.draft) }
                    .glassButton(prominent: true)
                    .disabled(license.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = license.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
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
                ForEach(model.steps, id: \.self) { step in
                    Circle()
                        .fill(step == model.step ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.back() }
            }
            Button(model.step == .welcome ? "Get Started" : model.step == .done ? "Start Using Isola" : "Continue") {
                if model.step == .done { model.finish() } else { model.advance() }
            }
            .keyboardShortcut(.defaultAction)
            // Past the license step with a license, or with Start Trial.
            .disabled(model.step == .license && license.status != .licensed)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
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
