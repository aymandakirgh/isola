import AppKit
import Observation
import SwiftUI

/// Selection + window-local state for the Settings window.
@MainActor @Observable
final class SettingsNav {
    var selection: String? = "general"
    var launchAtLogin = Preferences.shared.launchAtLogin {
        didSet {
            guard launchAtLogin != oldValue else { return }
            Preferences.shared.launchAtLogin = launchAtLogin
            // Registration can fail (e.g. app not in /Applications): reflect reality.
            let actual = Preferences.shared.launchAtLogin
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
}

struct SettingsPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let view: () -> AnyView
}

@MainActor
enum SettingsPages {
    private static let tints: [Color] = [.pink, .purple, .indigo, .teal, .orange, .mint, .cyan, .brown]

    static func all(nav: SettingsNav) -> [SettingsPage] {
        let modules = SettingsRegistry.sections.enumerated().map { i, s in
            SettingsPage(id: s.id, title: s.title, symbol: s.symbol, tint: tints[i % tints.count], view: s.view)
        }
        return [
            SettingsPage(id: "general", title: "General", symbol: "gearshape.fill", tint: .gray) { AnyView(GeneralPage(nav: nav)) },
            SettingsPage(id: "island", title: "Island", symbol: "capsule.fill", tint: .blue) { AnyView(IslandPage()) },
        ] + modules + [
            SettingsPage(id: "license", title: "License", symbol: "checkmark.seal.fill", tint: .green) { AnyView(LicensePage()) },
            SettingsPage(id: "about", title: "About", symbol: "info.circle.fill", tint: .gray) { AnyView(AboutPage()) },
        ]
    }
}

/// System Settings-style sidebar glyph: white symbol on a coloured rounded square.
struct SidebarIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
    }
}

struct SettingsRootView: View {
    @Bindable var nav: SettingsNav

    var body: some View {
        let pages = SettingsPages.all(nav: nav)
        let current = pages.first { $0.id == nav.selection } ?? pages[0]
        NavigationSplitView {
            List(pages, selection: $nav.selection) { page in
                Label {
                    Text(page.title)
                } icon: {
                    SidebarIcon(symbol: page.symbol, tint: page.tint)
                }
                .tag(page.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 240)
        } detail: {
            current.view()
                .navigationTitle(current.title)
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

@MainActor
enum SettingsWindow {
    static let nav = SettingsNav()
    private static var window: NSWindow?

    static func show(section: String? = nil) {
        if let section { nav.selection = section }
        let w = window ?? make()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    static func makeWindow(nav: SettingsNav) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Isola Settings"
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsRootView(nav: nav))
        w.setContentSize(NSSize(width: 680, height: 520))
        return w
    }

    private static func make() -> NSWindow {
        let w = makeWindow(nav: nav)
        w.center()
        return w
    }
}

// MARK: - Built-in pages

extension OutlineStyle {
    var title: String {
        switch self {
        case .none: "None"
        case .contrast: "Contrast"
        case .colored: "Colored"
        case .compact: "Compact"
        }
    }
}

struct TweakSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: { step(to: $0.rounded()) }), in: range)
                Text("\(value > 0 ? "+" : "")\(Int(value)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    /// Each whole-point step gets a haptic bump and a very quiet tick.
    private func step(to new: Double) {
        guard new != value else { return }
        value = new
        FineTuneFeedback.tick()
    }
}

/// Fine-tuner feedback, debounced so a fast drag doesn't rattle.
@MainActor
enum FineTuneFeedback {
    private static var last = Date.distantPast

    static func tick() {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.05 else { return }
        last = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Sounds.play("Tink", volume: 0.08)
    }
}

extension View {
    /// Tahoe: Liquid Glass buttons on macOS 26 and later, the bordered look before.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

struct GeneralPage: View {
    @Bindable var nav: SettingsNav
    @Bindable var prefs = Preferences.shared
    @Bindable var sync = SettingsSync.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $nav.launchAtLogin)
                Toggle(isOn: $sync.enabled) {
                    Text("Sync settings with iCloud Drive")
                    if sync.enabled { Text(sync.status) }
                }
            } footer: {
                Text("Turning it on applies the settings already in iCloud Drive, if there are any. The license, display choice, fine tuning, hidden calendars, dismissed events and live waveform stay on this Mac.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Display") {
                Picker("Show the island on", selection: $prefs.preferredDisplay) {
                    Text("Automatic").tag("auto")
                    Text("Main display").tag("main")
                    Text("Built-in display").tag("builtin")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        Text(screen.localizedName).tag(screen.localizedName)
                    }
                }
                .disabled(prefs.allDisplays)
                Toggle("Show on all displays", isOn: $prefs.allDisplays)
            }
            Section {
                Toggle("Simulated notch", isOn: $prefs.simulatedNotch)
                Toggle("Keep the pill visible when idle", isOn: $prefs.showIdlePill)
            } header: {
                Text("Displays without a notch")
            } footer: {
                Text("Without a notch, Isola floats as a pill under the top edge. A simulated notch docks it to the edge instead.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Fine tuning") {
                TweakSlider(title: "Width", value: $prefs.widthTweak, range: -40...40)
                TweakSlider(title: "Height", value: $prefs.heightTweak, range: -8...8)
                HStack {
                    Spacer()
                    Button("Reset") {
                        prefs.widthTweak = 0
                        prefs.heightTweak = 0
                    }
                    .glassButton()
                    .disabled(prefs.widthTweak == 0 && prefs.heightTweak == 0)
                }
            }
            Section {
                Toggle("In fullscreen apps", isOn: $prefs.hideInFullscreen)
                Toggle("While gaming", isOn: $prefs.hideWhileGaming)
                Toggle("In Mission Control", isOn: $prefs.hideInMissionControl)
                Toggle("From screenshots and recordings", isOn: $prefs.hideFromScreenCapture)
            } header: {
                Text("Hide the island")
            } footer: {
                Text("A fullscreen app hides the island only on its own display; Mission Control hides it everywhere.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Outline", selection: $prefs.outline) {
                    ForEach(OutlineStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Colored takes the playing artwork's colours, Compact draws a hairline only while the island is compact, and Contrast adds a brighter edge for dark wallpapers.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

struct IslandPage: View {
    @Bindable var prefs = Preferences.shared
    private static let hoverDelays: [Double] = [0, 0.3, 0.5, 0.8, 1.2]

    var body: some View {
        Form {
            Section("Interaction") {
                Picker("Expand on hover", selection: $prefs.hoverExpandDelay) {
                    ForEach(Self.hoverDelays, id: \.self) { delay in
                        Text(delay == 0 ? "Off" : "After \(delay.formatted()) s").tag(delay)
                    }
                }
                Toggle(isOn: $prefs.expandWhileInactive) {
                    Text("Expand while inactive")
                    Text("Clicking or hovering paused media opens its player.")
                }
                LabeledContent("Show notifications for") {
                    HStack {
                        Slider(value: Binding(get: { prefs.notificationDuration }, set: { prefs.notificationDuration = ($0 * 2).rounded() / 2 }), in: 1.5...8)
                        Text("\(prefs.notificationDuration.formatted()) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Natural swipe direction", isOn: $prefs.naturalSwipe)
            }
            Section("Activities") {
                Toggle(isOn: $prefs.duo) {
                    Text("Duo mode")
                    Text("With two live activities running, the next one waits in a bubble beside the island. Click the bubble to swap them.")
                }
            }
            Section {
                Picker("Speed", selection: $prefs.speed) {
                    ForEach(AnimationSpeed.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Overshoot", isOn: $prefs.overshoot)
            } header: {
                Text("Animation")
            } footer: {
                Text("Overshoot lets the island spring slightly past its size before settling.")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Sounds") {
                Toggle("Play a sound on unlock", isOn: $prefs.unlockSound)
                Toggle("Play a sound on lock", isOn: $prefs.lockSound)
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPage: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 112, height: 112)
            VStack(spacing: 4) {
                Text("Isola").font(.system(size: 26, weight: .bold))
                Text("Dynamic Island for your Mac").foregroundStyle(.secondary)
                Text("Version \(version) (\(build))").font(.callout).foregroundStyle(.tertiary)
            }
            links.font(.callout)
            Button("Show Welcome Again") { OnboardingWindow.show() }
                .glassButton()
                .padding(.top, 4)
            Spacer()
            Text("On macOS 26 or later you can hide the menu bar icon from System Settings › Menu Bar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var links: some View {
        let website = License.website
        if #available(macOS 26, *) {
            // Tahoe: Liquid Glass capsules that blend as one group.
            GlassEffectContainer {
                HStack(spacing: 8) {
                    Link("Website", destination: website).buttonStyle(.glass)
                    Link("Changelog", destination: website.appendingPathComponent("changelog")).buttonStyle(.glass)
                    Link("FAQs", destination: website.appendingPathComponent("faqs")).buttonStyle(.glass)
                }
            }
        } else {
            HStack(spacing: 10) {
                Link("Website", destination: website)
                Text("·").foregroundStyle(.tertiary)
                Link("Changelog", destination: website.appendingPathComponent("changelog"))
                Text("·").foregroundStyle(.tertiary)
                Link("FAQs", destination: website.appendingPathComponent("faqs"))
            }
        }
    }
}

/// The app icon in the bundle, or the repo copy when running unbundled (gallery, swift run).
@MainActor
enum AppIcon {
    static let image: NSImage = {
        if let icon = NSImage(named: "AppIcon") { return icon }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            let candidate = d.appendingPathComponent("Resources/AppIcon.png")
            if let icon = NSImage(contentsOf: candidate) { return icon }
            dir = d.deletingLastPathComponent()
        }
        return NSApp.applicationIconImage
    }()
}
