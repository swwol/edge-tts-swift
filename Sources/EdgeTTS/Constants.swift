import Foundation

enum EdgeTTSConstants {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"

    static let wssURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedClientToken)"
    // Updated to match Python edge-tts URL format
    static let voiceListURL = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=\(trustedClientToken)"

    static let defaultVoice = "en-US-EmmaMultilingualNeural"

    // Updated Chrome version to match Python edge-tts (v143)
    static let chromiumFullVersion = "143.0.3650.75"
    static let chromiumMajorVersion = String(chromiumFullVersion.split(separator: ".", maxSplits: 1).first ?? "143")
    static let secMsGecVersion = "1-\(chromiumFullVersion)"

    static var baseHeaders: [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromiumMajorVersion).0.0.0 Safari/537.36 Edg/\(chromiumMajorVersion).0.0.0",
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "en-US,en;q=0.9",
        ]
    }

    static var wssHeaders: [String: String] {
        var headers = [
            "Pragma": "no-cache",
            "Cache-Control": "no-cache",
            "Origin": "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
            "Sec-WebSocket-Version": "13",
        ]
        EdgeTTSConstants.baseHeaders.forEach { headers[$0.key] = $0.value }
        return headers
    }

    static var voiceHeaders: [String: String] {
        var headers = [
            "Authority": "speech.platform.bing.com",
            "Sec-CH-UA": "\" Not;A Brand\";v=\"99\", \"Microsoft Edge\";v=\"\(chromiumMajorVersion)\", \"Chromium\";v=\"\(chromiumMajorVersion)\"",
            "Sec-CH-UA-Mobile": "?0",
            "Accept": "*/*",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
        ]
        EdgeTTSConstants.baseHeaders.forEach { headers[$0.key] = $0.value }
        return headers
    }
    
    /// Generates a random MUID cookie value (matches Python edge-tts implementation)
    static func generateMUID() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
