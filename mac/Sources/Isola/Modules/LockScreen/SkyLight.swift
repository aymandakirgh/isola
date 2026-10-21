import AppKit

/// Private SkyLight calls that move windows onto a space drawn above the login
/// window, so widgets render on the Lock Screen. Every symbol is resolved with dlsym;
/// if any is missing the feature reports itself unavailable instead of crashing.
@MainActor
final class LockScreenSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    // ponytail: 400 is the absolute level Notification Center uses at screen lock (community-documented,
    // not public API); revisit if a macOS release moves the login window above it.
    private static let lockScreenLevel: Int32 = 400
    private static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let symbols = [
        "SLSMainConnectionID", "SLSSpaceCreate", "SLSSpaceSetAbsoluteLevel", "SLSShowSpaces", "SLSSpaceAddWindowsAndRemoveFromSpaces",
    ]

    /// True when every SkyLight symbol resolves (checked without creating a space).
    static let available: Bool = {
        guard let handle = dlopen(path, RTLD_LAZY) else { return false }
        return symbols.allSatisfy { dlsym(handle, $0) != nil }
    }()

    /// Created on first use (the first lock), then kept for the app's lifetime.
    static let shared: LockScreenSpace? = LockScreenSpace()

    private let connection: Int32
    private let space: UInt64
    private let addWindows: AddWindows

    private init?() {
        guard Self.available, let handle = dlopen(Self.path, RTLD_LAZY) else {
            NSLog("isola: SkyLight unavailable; Lock Screen widgets disabled")
            return nil
        }
        func fn<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(handle, name), to: T.self) }
        let main = fn("SLSMainConnectionID", MainConnection.self)
        let create = fn("SLSSpaceCreate", SpaceCreate.self)
        let setLevel = fn("SLSSpaceSetAbsoluteLevel", SetAbsoluteLevel.self)
        let show = fn("SLSShowSpaces", ShowSpaces.self)
        addWindows = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self)
        connection = main()
        space = create(connection, 1, 0)
        guard space != 0 else {
            NSLog("isola: SLSSpaceCreate failed; Lock Screen widgets disabled")
            return nil
        }
        _ = setLevel(connection, space, Self.lockScreenLevel)
        _ = show(connection, [NSNumber(value: space)] as CFArray)
    }

    /// Moves a window onto the lock-screen space (removing it from every other space).
    func adopt(_ window: NSWindow) {
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
    }
}
