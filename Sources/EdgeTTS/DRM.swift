import CryptoKit
import Foundation

enum DRM {
    @MainActor private static var clockSkewSeconds: TimeInterval = 0
    private static let winEpoch: TimeInterval = 11_644_473_600 // Seconds between 1601 and 1970

    @MainActor static func adjustClockSkew(by seconds: TimeInterval) {
        clockSkewSeconds += seconds
    }

    @MainActor static func currentUnixTimestamp() -> TimeInterval {
        Date().timeIntervalSince1970 + clockSkewSeconds
    }

    static func parseRFC2616Date(_ value: String) -> TimeInterval? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)?.timeIntervalSince1970
    }

    @MainActor static func handleClientResponseError(_ response: HTTPURLResponse) throws {
        guard let serverDate = response.value(forHTTPHeaderField: "Date") else {
            throw EdgeTTSError.skewAdjustmentFailed("Server did not return a Date header")
        }
        guard let parsed = parseRFC2616Date(serverDate) else {
            throw EdgeTTSError.skewAdjustmentFailed("Failed to parse server date: \(serverDate)")
        }
        let clientDate = currentUnixTimestamp()
        adjustClockSkew(by: parsed - clientDate)
    }

    /// Generates the Sec-MS-GEC token value (matches Python edge-tts implementation exactly)
    /// See: https://github.com/rany2/edge-tts/issues/290#issuecomment-2464956570
    @MainActor static func generateSecMSGEC(timestamp: TimeInterval? = nil) -> String {
        // Get the current timestamp in Unix format with clock skew correction
        var ticks = timestamp ?? currentUnixTimestamp()
        
        // Switch to Windows file time epoch (1601-01-01 00:00:00 UTC)
        ticks += winEpoch
        
        // Round down to the nearest 5 minutes (300 seconds)
        ticks -= ticks.truncatingRemainder(dividingBy: 300)
        
        // Convert to 100-nanosecond intervals (Windows file time format)
        // S_TO_NS / 100 = 1e9 / 100 = 1e7
        let fileTimeUnits = ticks * 10_000_000

        // Create the string to hash by concatenating the ticks and the trusted client token
        let toHash = String(format: "%.0f%@", fileTimeUnits, EdgeTTSConstants.trustedClientToken)
        
        // Compute the SHA256 hash and return the uppercased hex digest
        let digest = SHA256.hash(data: Data(toHash.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}
