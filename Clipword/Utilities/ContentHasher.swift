import CryptoKit
import Foundation

enum ContentHasher {
    /// SHA-256 hex of a stored payload. Hashing ~10MB costs single-digit ms —
    /// far cheaper than byte-comparing a copy against every blob in history,
    /// and it never faults `.externalStorage` data for non-matching rows.
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
