import AppKit

/// MediaRemote through Apple's own `/usr/bin/perl`: macOS 15.4+ only answers
/// Apple-signed processes, so the bundled helper (Helpers/MediaRemoteHelper.m) runs
/// inside perl and streams JSON lines back; commands go down its stdin.
@MainActor
final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private(set) var latest: NowPlayingSnapshot?
    var onUpdate: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var artwork: NSImage?
    private var artworkID = ""
    private var restarts = 0

    private var helper: URL? { Bundle.main.url(forResource: "MediaRemoteHelper", withExtension: "dylib") }
    private var script: URL? { Bundle.main.url(forResource: "mediaremote", withExtension: "pl") }

    func start() {
        guard process == nil, let helper, let script else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, helper.path, "isola_mediaremote"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { MediaRemoteBridge.shared.consume(data) } }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let bridge = MediaRemoteBridge.shared
                    bridge.process = nil
                    bridge.input = nil
                    // Back off if the helper keeps dying (e.g. MediaRemote changed again).
                    bridge.restarts += 1
                    guard bridge.restarts < 5 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(bridge.restarts) * 2) { bridge.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("isola: MediaRemote helper failed to start: %@", error.localizedDescription)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// `cmd <MRCommand>`, `seek <seconds>`, `rate <x>` or `like <0|1>`.
    func send(_ line: String) {
        try? input?.write(contentsOf: Data((line + "\n").utf8))
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(Data(line))
        }
    }

    private func parse(_ line: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        restarts = 0
        func num(_ key: String) -> Double? { (o[key] as? NSNumber)?.doubleValue }
        var s = NowPlayingSnapshot()
        s.title = o["title"] as? String ?? ""
        s.artist = o["artist"] as? String ?? ""
        s.album = o["album"] as? String ?? ""
        s.duration = num("duration") ?? 0
        s.elapsed = num("elapsed") ?? 0
        s.timestamp = Date(timeIntervalSince1970: num("timestamp") ?? Date().timeIntervalSince1970)
        let rate = num("rate") ?? 0
        s.rate = rate > 0 ? rate : 1
        s.isPlaying = (num("playing") ?? 0) > 0
        s.shuffle = (num("shuffle") ?? 1) >= 2
        s.repeatMode = switch Int(num("repeat") ?? 1) { case 2: 1; case 3: 2; default: 0 }
        s.explicit = (num("explicit") ?? 0) > 0
        s.inTransition = (num("transition") ?? 0) > 0
        s.canLike = (num("canLike") ?? 0) > 0
        s.liked = num("liked").map { $0 > 0 }
        s.audioFormat = NowPlayingExtras.audioFormat(tier: num("tier").map { Int($0) }, rendering: num("rendering").map { Int($0) })
        if let pid = num("pid"), pid > 0 { s.bundleID = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier }
        if let b64 = o["artwork"] as? String, let bytes = Data(base64Encoded: b64) {
            artwork = NSImage(data: bytes)
            artworkID = o["artworkID"] as? String ?? ""
        } else if o["artworkID"] == nil {
            artwork = nil
            artworkID = ""
        }
        if !artworkID.isEmpty, (o["artworkID"] as? String) == artworkID {
            s.artwork = artwork
            s.artworkID = artworkID
        }
        // Media without metadata (a video, an untitled stream) still counts while it plays or has a length.
        let untitled = s.title.isEmpty && s.artist.isEmpty
        latest = untitled && !s.isPlaying && s.duration <= 0 ? nil : s
        onUpdate?()
    }
}
