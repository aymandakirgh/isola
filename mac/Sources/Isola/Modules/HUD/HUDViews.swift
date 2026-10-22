import SwiftUI

/// One region of a HUD: the symbol wing, the value wing, or the label row under the notch.
struct HUDPart: View {
    enum Part { case leading, trailing, label }
    let part: Part
    let s: HUDSnapshot
    let look: HUDLook
    /// Rubber band past 0% / 100% (`HUDModel.stretch`).
    var stretch: Double = 0

    private var silent: Bool { s.kind == .volume && (s.muted || s.level <= 0) }
    private var glowing: Bool { look.style == .glow && !silent }

    /// What the narrow trailing wing carries.
    enum Wing: Equatable { case bar, percent, decibels, mute }

    /// Never blank: the number (the percentage, or decibels) or, with neither, a compact bar. Muted,
    /// the number reads "Mute", unless the label row below already says "Muted".
    static func wing(labels: Bool, showPercentage: Bool, decibels: Bool, silent: Bool) -> Wing {
        if silent, !labels, showPercentage || decibels { return .mute }
        return decibels ? .decibels : showPercentage ? .percent : .bar
    }

    /// Stretched toward the push (right at the top, left at the bottom) and a little thinner;
    /// `amount` is the share of its width a bar gains at full stretch (more for the short one).
    private func rubberBand(_ bar: some View, amount: CGFloat) -> some View {
        bar.scaleEffect(x: 1 + amount * stretch, y: 1 - 0.3 * stretch, anchor: s.level >= 0.5 ? .leading : .trailing)
    }

    var body: some View {
        switch part {
        case .leading: symbol.padding(.leading, 11)
        case .trailing: value.padding(.trailing, 11)
        case .label: label
        }
    }

    @ViewBuilder private var symbol: some View {
        if s.kind == .brightness {
            Image(systemName: look.displaySymbol ? "display" : s.level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .islandSymbol(16)
                .foregroundStyle(glowing ? Palette.amber : Palette.ink)
                .shadow(color: glowing ? Palette.amber.opacity(0.9 * s.level) : .clear, radius: 7 * s.level)
                .contentTransition(.symbolEffect(.replace))
        } else if silent {
            Image(systemName: "speaker.slash.fill").islandSymbol(15).contentTransition(.symbolEffect(.replace))
        } else if look.output == .device, let device = s.output.symbol {
            Image(systemName: device).islandSymbol(16)
                .foregroundStyle(s.output.deviceTint.map { Color(nsColor: $0) } ?? Palette.ink)
                .contentTransition(.symbolEffect(.replace))
        } else {
            // Wave count follows the level, like the macOS speaker glyph.
            Image(systemName: "speaker.wave.3.fill", variableValue: s.level).islandSymbol(15)
        }
    }

    /// The level's colour in the progress style: white, the accent colour, a gradient of the HUD's
    /// own (warm light for the display; the output device's colour, or a cool blue, for sound) or
    /// the display's amber glow. Grey while muted.
    private var tint: AnyShapeStyle {
        if silent { return AnyShapeStyle(Palette.muted) }
        switch look.style {
        case .white, .decibel: return AnyShapeStyle(Palette.ink)
        case .accent: return AnyShapeStyle(Color(nsColor: .controlAccentColor))
        case .glow: return AnyShapeStyle(Palette.amber)
        case .stylized:
            let start = s.kind == .brightness ? Palette.amber : s.output.deviceTint.map { Color(nsColor: $0) } ?? Self.sky
            return AnyShapeStyle(LinearGradient(colors: [start, Palette.ink], startPoint: .leading, endPoint: .trailing))
        }
    }

    private static let sky = Color(red: 0.45, green: 0.72, blue: 1)

    private func bar(_ amount: CGFloat) -> some View {
        rubberBand(HUDBar(value: s.level, fill: tint, glow: glowing, spring: look.fillSpring), amount: amount).opacity(silent ? 0.45 : 1)
    }

    private var percent: String { "\(Int((s.level * 100).rounded()))%" }

    private var decibelText: String {
        let db = s.decibels ?? HUDOutput.approximateDecibels(s.level)
        return db <= -63 ? "−∞ dB" : "\(Int(db.rounded())) dB".replacingOccurrences(of: "-", with: "−")
    }

    /// Text styles share one compact type treatment so they fit the narrow wing.
    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .shadow(color: glowing ? Palette.amber.opacity(0.7) : .clear, radius: 4)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(value: s.level))
    }

    @ViewBuilder private var value: some View {
        switch Self.wing(labels: look.labels, showPercentage: look.showPercentage, decibels: look.style == .decibel && s.kind == .volume, silent: silent) {
        case .bar: bar(0.25).frame(width: 26)
        case .percent: valueText(percent)
        case .decibels: valueText(decibelText)
        case .mute: valueText("Mute")
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Text(labelText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(maxWidth: 74, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            bar(0.07)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var labelText: String {
        if s.kind == .brightness { return "Brightness" }
        if silent { return "Muted" }
        return look.output == .symbol ? "Volume" : s.output.label
    }
}

/// The HUD's level bar: the progress style's colour or gradient, filling at the HUD's own speed.
struct HUDBar: View {
    var value: Double
    var fill: AnyShapeStyle
    var glow = false
    var height: CGFloat = 5
    var spring: Animation

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(fill).opacity(0.22)
                Capsule().fill(fill)
                    .frame(width: max(height, geo.size.width * max(0, min(1, value))))
                    .shadow(color: glow ? Palette.amber.opacity(0.8) : .clear, radius: 4)
            }
        }
        .frame(height: height)
        .animation(spring, value: value)
    }
}

/// HUD region bound to live state (observes the model and preferences).
struct LiveHUD: View {
    let part: HUDPart.Part
    var body: some View {
        let s = HUDModel.shared.snapshot
        HUDPart(part: part, s: s, look: HUDPreferences.shared.look(s.kind), stretch: HUDModel.shared.stretch)
    }
}

struct HUDSettingsView: View {
    @Bindable var hud = HUDPreferences.shared

    var body: some View {
        let kind = hud.page
        Form {
            Section {
                Toggle("Replace the macOS volume and brightness HUD", isOn: $hud.replaceSystemHUD)
                PermissionRow(permission: Permission.accessibility)
            } header: {
                Text("System HUD")
            } footer: {
                note("When off, Isola still shows its HUD whenever the volume changes, next to the macOS one. Brightness needs the keys, so it only appears when this is on, with Accessibility allowed.")
            }
            Section {
                Toggle("Show the HUD for changes made elsewhere", isOn: $hud.showExternalChanges)
                    .disabled(!hud.replaceSystemHUD)
            } header: {
                Text("Sync")
            } footer: {
                note("Volume changed by other apps, Control Center or your AirPods. Turning this off needs the option above, so Isola can tell those changes from your key presses.")
            }
            Section {
                Toggle("Brightness and volume from BetterDisplay", isOn: $hud.betterDisplay)
            } header: {
                Text("Other displays")
            } footer: {
                note("For monitors BetterDisplay controls. In BetterDisplay, turn on Settings › Application › Integration › Dispatch OSD notifications, and hide its own OSD in its Keyboard settings.")
            }
            Section {
                Picker("HUD", selection: $hud.page) {
                    ForEach(HUDKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Link settings between HUDs", isOn: Binding(get: { hud.linked }, set: { on in
                    if on { hud.link(from: kind) } else { hud.linked = false }
                }))
            } header: {
                Text("Appearance")
            } footer: {
                note("Linked, a change on either page applies to both HUDs; Glow stays with Display and Decibels with Sound.")
            }
            Section {
                Picker("Progress style", selection: binding(kind, \.style)) {
                    ForEach(HUDProgressStyle.allCases.filter { $0.fits(kind) }) { Text($0.title).tag($0) }
                }
                Toggle("Show percentage", isOn: binding(kind, \.showPercentage))
                    .disabled(hud.look(kind).style == .decibel)
                Toggle("Show labels", isOn: binding(kind, \.labels))
                if kind == .volume {
                    Picker("Output device", selection: $hud.outputStyle) {
                        ForEach(HUDOutputStyle.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    Toggle("Display symbol for brightness", isOn: $hud.displaySymbol)
                }
            } header: {
                Text(kind == .volume ? "Sound HUD" : "Display HUD")
            } footer: {
                if hud.look(kind).style == .decibel { note("Decibels shows the level in dB, in place of the percentage.") }
            }
            Section {
                Picker("Speed", selection: binding(kind, \.speed)) {
                    ForEach(AnimationSpeed.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                LabeledContent("Stays visible for") {
                    HStack {
                        Slider(value: binding(kind, \.duration), in: 0.8...4)
                        Text(String(format: "%.1f s", hud.look(kind).duration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Motion")
            } footer: {
                note("How fast this HUD springs in and out and fills its bar. The whole island's speed and overshoot are in Island › Animation; with overshoot, the bar also stretches when you press past 0% or 100%.")
            }
            Section("Feedback") {
                Toggle("Play feedback when the volume is changed", isOn: $hud.feedbackSound)
            }
        }
        .formStyle(.grouped)
    }

    /// One setting of the HUD on show; with Link on, an edit lands on both.
    private func binding<V>(_ kind: HUDKind, _ path: WritableKeyPath<HUDLook, V>) -> Binding<V> {
        Binding(get: { hud.look(kind)[keyPath: path] }, set: { hud.edit(kind, path, $0) })
    }

    /// Section footer, left-aligned like the other settings pages.
    private func note(_ text: String) -> some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
