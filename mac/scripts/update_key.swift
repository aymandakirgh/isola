// The Ed25519 key that signs release zips: Isola installs an update in place only when its
// signature verifies against the public key built into the app (Updates.signingKey).
//   swift scripts/update_key.swift keygen       makes the key in ~/.config/isola/update-signing.key (mode 600,
//                                               never overwritten) and prints only its public key, for the app
//   swift scripts/update_key.swift sign <file>  prints the file's signature (base64); build.sh signs Isola.zip
// The private key stays in that file: back it up offline, never in the repo.
import CryptoKit
import Foundation

let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/isola/update-signing.key").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update_key: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen" where args.count == 1:
    let key = Curve25519.Signing.PrivateKey(), raw = key.rawRepresentation
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    // O_EXCL: an existing key is never replaced, since installed apps trust only its public key.
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { fail(errno == EEXIST ? "\(path) already exists, not overwriting it" : "can't create \(path)") }
    let written = raw.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    guard written == raw.count else {
        unlink(path)
        fail("couldn't write \(path)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2:
    guard let raw = FileManager.default.contents(atPath: path), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no signing key in \(path) (keygen makes one)")
    }
    guard let data = FileManager.default.contents(atPath: args[1]), let signature = try? key.signature(for: data) else { fail("can't sign \(args[1])") }
    print(signature.base64EncodedString())
default:
    fail("usage: swift scripts/update_key.swift keygen | sign <file>")
}
