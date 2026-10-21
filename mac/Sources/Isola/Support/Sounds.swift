import AppKit

/// Bundled UI sounds (Resources/Sounds/*.wav), falling back to system sounds by name.
@MainActor
enum Sounds {
    private static var cache: [String: NSSound] = [:]
    /// Set while another Mac's settings are applied: a sound turned on there doesn't preview here.
    static var muted = false

    static func play(_ name: String, volume: Float = 1) {
        guard !muted else { return }
        let sound = cache[name] ?? load(name)
        guard let sound else { return }
        cache[name] = sound
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    // Each sound setting's sound, played by the event and as its preview in Settings.
    static func unlock() { play("unlock") }
    static func lock() { play("unlock", volume: 0.6) }
    static func lowBattery() { play("Funk") }
    static func sleepFocus() { play("Purr", volume: 0.5) }

    private static func load(_ name: String) -> NSSound? {
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(named: NSSound.Name(name))
    }
}
