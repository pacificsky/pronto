import AppKit
import CryptoKit
import Foundation

/// Fetch-once loader for the cloud's per-device product images (the
/// color-accurate render behind the popup watermark).
///
/// Two cache tiers: an in-memory dictionary for the session, and a disk copy
/// under Application Support keyed by a hash of the URL — so each unique image
/// URL is downloaded exactly once, ever, and survives relaunches/offline. A new
/// machine (or a recolor) changes the URL, which is a new key → one new fetch.
///
/// Every failure path (network down, non-2xx, undecodable data) degrades to
/// `nil`: the watermark simply doesn't render. Nothing is logged — the URL
/// carries the machine's model + color, and errors here are cosmetic.
@MainActor
enum MachineImageCache {
    private static var memory: [URL: NSImage] = [:]

    static func image(for url: URL) async -> NSImage? {
        if let hit = memory[url] { return hit }
        let file = cacheFile(for: url)
        // Disk and network I/O happen off the main actor; only the decoded
        // image comes back.
        let data: Data? = await Task.detached(priority: .utility) {
            if let onDisk = try? Data(contentsOf: file) { return onDisk }
            guard let (fetched, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fetched.write(to: file, options: .atomic)
            return fetched
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
        memory[url] = image
        return image
    }

    private static func cacheFile(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pronto/images/\(hash).png")
    }
}
