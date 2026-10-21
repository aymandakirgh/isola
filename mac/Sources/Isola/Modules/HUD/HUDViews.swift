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

    /// Stretched toward the push (right at the top, left at the bottom) and a little thinner;
    /// `amount` is the width gained at full stretch, so short and long bars move alike.
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
                .foregroundStyle(look.glow ? Palette.amber : Palette.ink)
                .shadow(color: look.glow ? Palette.amber.opacity(0.9 * s.level) : .clear, radius: 7 * s.level)
                .contentTransition(.symbolEffect(.replace))
        } else if silent {
            Image(systemName: "speaker.slash.fill").islandSymbol(15).contentTransition(.symbolEffect(.replace))
        } else if let device = s.output.symbol {
            Image(systemName: device).islandSymbol(16).contentTransition(.symbolEffect(.replace))
        } else {
            // Wave count follows the level, like the macOS speaker glyph.
            Image(systemName: "speaker.wave.3.fill", variableValue: s.level).islandSymbol(15)
        }
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
            .foregroundStyle(silent ? Palette.muted : Palette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(value: s.level))
    }

    @ViewBuilder private var value: some View {
        let bar = rubberBand(LevelBar(value: s.level, tint: silent ? Palette.muted : Palette.ink, height: 5).frame(width: 26), amount: 0.25).opacity(silent ? 0.45 : 1)
        if silent, look.style != .bar {
            valueText("Mute")
        } else if look.style == .decibels, s.kind == .volume {
            valueText(decibelText)
        } else if look.labels || look.style == .percentage {
            // With labels the bar lives in the row below, so the wing carries the number.
            valueText(percent)
        } else {
            bar
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Text(s.kind == .brightness ? "Brightness" : silent ? "Muted" : s.output.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .frame(maxWidth: 74, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            rubberBand(LevelBar(value: s.level, tint: silent ? Palette.muted : Palette.ink, height: 5), amount: 0.07)
                .opacity(silent ? 0.45 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// HUD region bound to live state (observes the model and preferences).
struct LiveHUD: View {
    let part: HUDPart.Part
    var body: some View {
        HUDPart(part: part, s: HUDModel.shared.snapshot, look: HUDPreferences.shared.look, stretch: HUDModel.shared.stretch)
    }
}

struct HUDSettingsView: View {
    @Bindable var hud = HUDPreferences.shared
    @Bindable var core = Preferences.shared
    var model = HUDModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Replace the macOS volume and brightness HUD", isOn: $hud.replaceSystemHUD)
                if hud.replaceSystemHUD, !model.accessibilityTrusted {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Isola needs Accessibility access to catch the volume and brightness keys.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Access…") { HUDModule.requestAccessibility() }
                    }
                }
            } header: {
                Text("System HUD")
            } footer: {
                Text("When off, Isola still shows its HUD whenever the volume changes, next to the macOS one. Brightness needs the keys, so it only appears when this is on.")
            }
            Section("Appearance") {
                Picker("Style", selection: $hud.style) {
                    ForEach(HUDStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show labels", isOn: $hud.showLabels)
                Toggle("Glow on the brightness HUD", isOn: $hud.glow)
                Toggle("Display symbol for brightness", isOn: $hud.displaySymbol)
            }
            Section {
                Picker("Speed", selection: $core.speed) {
                    ForEach(AnimationSpeed.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Overshoot", isOn: $core.overshoot)
                LabeledContent("Stays visible for") {
                    HStack {
                        Slider(value: $hud.duration, in: 0.8...4)
                        Text(String(format: "%.1f s", hud.duration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Motion")
            } footer: {
                Text("Speed and overshoot apply to the whole island.")
            }
            Section("Sound") {
                Toggle("Play feedback when the volume is changed", isOn: $hud.feedbackSound)
            }
        }
        .formStyle(.grouped)
    }
}
