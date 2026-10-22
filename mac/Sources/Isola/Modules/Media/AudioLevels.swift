import AudioToolbox
import CoreAudio
import Observation

/// Live waveform: taps the system output (Core Audio process tap, macOS 14.2+) and
/// reduces it to four band levels. Runs only while something plays and the
/// "Live waveform" setting is on; macOS asks for System Audio Recording access once.
@MainActor @Observable
final class AudioLevels {
    static let shared = AudioLevels()

    /// Bass → treble, 0...1, smoothed.
    private(set) var bands: [Float] = [0, 0, 0, 0]
    /// True once real (non-zero) audio has arrived; a denied tap only ever delivers zeros.
    private(set) var live = false
    /// What the last runs of the tap heard: nil before any, true once real audio came through, false after
    /// `grace` seconds of playback with only silence (System Audio Recording is off for Isola). Kept across pauses.
    private(set) var heard: Bool?

    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var procID: AudioDeviceIOProcID?
    @ObservationIgnored private let analyzer = BandAnalyzer()
    @ObservationIgnored private var startedAt = Date.distantPast

    /// ponytail: a fixed 5 s; a track that opens with longer silence reads as "no access" until its audio starts.
    static let grace: TimeInterval = 5
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    /// `heard` given: a stand-in for the gallery (the tap never starts on its own).
    init(heard: Bool? = nil) { self.heard = heard }

    var running: Bool { procID != nil }

    func setActive(_ on: Bool) {
        if on, !running { start() } else if !on, running { stop() }
    }

    private func start() {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr, let output = Self.defaultOutputUID() else { return stop() }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Isola Levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID) == noErr else { return stop() }
        let analyzer = analyzer
        analyzer.reset(sampleRate: Self.sampleRate(of: aggregateID))
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, DispatchQueue(label: "isola.levels")) { _, input, _, _, _ in
            guard let levels = analyzer.consume(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { AudioLevels.shared.publish(levels) } }
        }
        guard status == noErr, let proc, AudioDeviceStart(aggregateID, proc) == noErr else { procID = proc; return stop() }
        procID = proc
        // The tap only runs while something plays: still silent after the grace period, it can't hear.
        let started = Date()
        startedAt = started
        Task {
            try? await Task.sleep(for: .seconds(Self.grace))
            if running, startedAt == started, !live { heard = false }
        }
    }

    private func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        bands = [0, 0, 0, 0]
        live = false
    }

    private func publish(_ levels: BandAnalyzer.Levels) {
        guard running else { return }
        if levels.peak > 0, !live { live = true; heard = true }
        // Fast attack, slow release, like a VU meter.
        bands = zip(bands, levels.bands).map { old, new in new > old ? old + (new - old) * 0.6 : old + (new - old) * 0.18 }
    }

    // MARK: - Core Audio lookups

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func sampleRate(of device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(48_000)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }
}

/// Splits mono-mixed samples into four bands with RBJ biquads (low-pass 150 Hz,
/// band-pass 450 Hz and 1.6 kHz, high-pass 4 kHz): ~20 multiply-adds per sample, no FFT.
final class BandAnalyzer: @unchecked Sendable {
    struct Levels { var bands: [Float]; var peak: Float }

    private struct Biquad {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        enum Kind { case lowPass, bandPass, highPass }

        init(_ kind: Kind, hz: Double, q: Double, sampleRate: Double) {
            let w = 2 * Double.pi * hz / sampleRate, c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
            let (b0, b1, b2): (Double, Double, Double) = switch kind {
            case .lowPass: ((1 - c) / 2, 1 - c, (1 - c) / 2)
            case .bandPass: (alpha, 0, -alpha)
            case .highPass: ((1 + c) / 2, -(1 + c), (1 + c) / 2)
            }
            (self.b0, self.b1, self.b2) = (Float(b0 / a0), Float(b1 / a0), Float(b2 / a0))
            (a1, a2) = (Float(-2 * c / a0), Float((1 - alpha) / a0))
        }

        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var filters: [Biquad] = []
    private var energy: [Float] = [0, 0, 0, 0]
    private var peak: Float = 0
    private var count = 0
    private var window = 1600

    func reset(sampleRate: Double) {
        filters = [
            Biquad(.lowPass, hz: 150, q: 0.707, sampleRate: sampleRate),
            Biquad(.bandPass, hz: 450, q: 0.9, sampleRate: sampleRate),
            Biquad(.bandPass, hz: 1600, q: 0.9, sampleRate: sampleRate),
            Biquad(.highPass, hz: 4000, q: 0.707, sampleRate: sampleRate),
        ]
        window = Int(sampleRate / 30)  // publish ~30 times a second
        energy = [0, 0, 0, 0]
        peak = 0
        count = 0
    }

    /// Interleaved or planar float buffers; returns levels once per window.
    func consume(_ buffers: UnsafeMutableAudioBufferListPointer) -> Levels? {
        var result: Levels?
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            for frame in 0..<frames {
                var x: Float = 0
                for c in 0..<channels { x += data[frame * channels + c] }
                result = feed(x / Float(channels)) ?? result
            }
        }
        return result
    }

    func feed(_ x: Float) -> Levels? {
        peak = max(peak, abs(x))
        for i in 0..<4 {
            let y = filters[i].run(x)
            energy[i] += y * y
        }
        count += 1
        guard count >= window else { return nil }
        // RMS in dB, mapped from -50...-6 dBFS to 0...1; treble gets a boost since it carries less energy.
        let gains: [Float] = [0, 3, 6, 10]
        let bands = (0..<4).map { i -> Float in
            let rms = sqrt(energy[i] / Float(count))
            let db = 20 * log10(max(rms, 1e-7)) + gains[i]
            return min(1, max(0, (db + 50) / 44))
        }
        let levels = Levels(bands: bands, peak: peak)
        energy = [0, 0, 0, 0]
        peak = 0
        count = 0
        return levels
    }

    /// Runs with `Isola --gallery`: a bass tone lights band 0, a treble tone band 3, silence nothing.
    static func selfCheck() {
        func levels(_ hz: Double, amplitude: Float = 0.5) -> Levels {
            let a = BandAnalyzer()
            a.reset(sampleRate: 48_000)
            var last: Levels?
            for n in 0..<48_000 { last = a.feed(amplitude * Float(sin(2 * Double.pi * hz * Double(n) / 48_000))) ?? last }
            return last!
        }
        let bass = levels(60), treble = levels(9_000), silence = levels(1_000, amplitude: 0)
        precondition(bass.bands[0] > 0.8 && bass.bands[3] < 0.3, "bass → band 0: \(bass.bands)")
        precondition(treble.bands[3] > 0.8 && treble.bands[0] < 0.3, "treble → band 3: \(treble.bands)")
        precondition(silence.peak == 0 && silence.bands.allSatisfy { $0 == 0 }, "silence: \(silence.bands)")
    }
}
