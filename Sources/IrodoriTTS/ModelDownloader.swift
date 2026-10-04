import Foundation
import CryptoKit

/// Downloads to disk, retaining completed verified files for a subsequent retry.
/// Use a manifest URL pinned to a Hugging Face commit SHA, never a moving main branch.
public actor ModelDownloader {
    public init() {}

    public func download(manifestURL: URL, to destination: URL,
                         progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) async throws {
        guard manifestURL.scheme == "https" else { throw IrodoriError.invalid("Use an HTTPS manifest URL") }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw IrodoriError.invalid("Destination already exists. Select a new folder or verify the existing model.")
        }
        // Distinct manifests must not share a staging directory during retries.
        let key = SHA256.hash(data: Data(manifestURL.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(key).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw IrodoriError.invalid("Manifest download failed") }
        let manifest = try ModelBundle.manifest(from: data)
        let base = manifestURL.deletingLastPathComponent()
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let target = try ModelBundle.safeURL(entry.path, under: staging)
            progress(index, manifest.files.count, entry.path)
            if let size = try? files.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
               size.int64Value == entry.bytes, (try? ModelBundle.checksum(target)) == entry.sha256 { continue }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temporary, downloadResponse) = try await URLSession.shared.download(from: base.appendingPathComponent(entry.path))
            defer { try? files.removeItem(at: temporary) }
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200,
                  (try files.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == entry.bytes,
                  try ModelBundle.checksum(temporary) == entry.sha256 else {
                throw IrodoriError.invalid("Downloaded file failed verification: \(entry.path)")
            }
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: temporary, to: target)
        }
        try Task.checkCancellation()
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try ModelBundle.validate(at: staging)
        try files.moveItem(at: staging, to: destination)
        progress(manifest.files.count, manifest.files.count, "Complete")
    }
}
