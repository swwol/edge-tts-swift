
import Foundation
import NaturalLanguage

/// A lightweight Swift client for Microsoft Edge Text-to-Speech.
///
/// `EdgeTTSClient` can:
/// - Fetch the list of available voices via the Edge voices endpoint.
/// - Synthesize text to audio in one shot (`synthesize(text:...)`).
/// - Stream synthesis events (`stream(text:...)`) including audio chunks and optional boundary metadata.
///
/// The streaming API is built on `URLSessionWebSocketTask`.
///
/// - Important: This client is marked `@unchecked Sendable` because it holds a `URLSession` and a delegate.
///   Treat instances as logically thread-safe only if you avoid mutating shared state from callbacks.

public final class EdgeTTSClient: @unchecked Sendable {
    private let session: URLSession
    private let connectTimeout: TimeInterval
    private let receiveTimeout: TimeInterval
    private let wsDelegate = WebSocketDelegate()

    /// Creates a new `EdgeTTSClient`.
    ///
    /// - Parameters:
    ///   - session: The `URLSession` used for the non-WebSocket HTTP request in ``listVoices()``.
    ///     WebSocket streaming uses an internal ephemeral session.
    ///   - connectTimeout: Timeout (seconds) for establishing HTTP/WebSocket requests.
    ///   - receiveTimeout: Timeout (seconds) for receiving WebSocket messages while streaming.
    public init(
        session: URLSession = .shared,
        connectTimeout: TimeInterval = 10,
        receiveTimeout: TimeInterval = 60
    ) {
        self.session = session
        self.connectTimeout = connectTimeout
        self.receiveTimeout = receiveTimeout
    }

    // MARK: - Public API

    /// Fetches the list of available voices.
    ///
    /// This calls the Edge voices list endpoint and decodes the response into ``Voice`` values.
    /// If the service returns HTTP 403, the client asks ``DRM`` to adjust for clock skew and retries once.
    ///
    /// - Returns: An array of available voices.
    /// - Throws: ``EdgeTTSError`` if URL construction fails, decoding fails, or the HTTP response is not successful.
    public func listVoices() async throws -> [Voice] {
        let token = await DRM.generateSecMSGEC()
        let urlString = "\(EdgeTTSConstants.voiceListURL)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
        guard let url = URL(string: urlString) else {
            throw EdgeTTSError.unexpectedResponse("Failed to build voice list URL")
        }

        var request = URLRequest(url: url)
        EdgeTTSConstants.voiceHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        // Add MUID cookie (matches Python edge-tts implementation)
        request.addValue("muid=\(EdgeTTSConstants.generateMUID());", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = connectTimeout

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw EdgeTTSError.unexpectedResponse("Voice list call did not return HTTP response")
            }
            if http.statusCode == 403 {
                try await DRM.handleClientResponseError(http)
                return try await listVoices()
            }
            guard (200..<300).contains(http.statusCode) else {
                throw EdgeTTSError.unexpectedResponse("Voice list call failed with \(http.statusCode)")
            }
            return try JSONDecoder().decode([Voice].self, from: data).map { voice in
                let tag = voice.voiceTag ?? VoiceTag(contentCategories: [], voicePersonalities: [])
                return Voice(
                    name: voice.name,
                    shortName: voice.shortName,
                    gender: voice.gender,
                    locale: voice.locale,
                    localeName: voice.localeName,
                    sampleRateHertz: voice.sampleRateHertz,
                    voiceType: voice.voiceType,
                    status: voice.status,
                    voiceTag: tag
                )
            }
        }
    }

    /// Synthesizes text into a single audio buffer.
    ///
    /// This is a convenience wrapper over ``stream(text:config:outputFormat:)`` that collects
    /// all `.audio` events into one `Data` value.
    ///
    /// - Parameters:
    ///   - text: The text to synthesize.
    ///   - config: Synthesis configuration including voice, rate, pitch, volume, and boundary settings.
    ///   - outputFormat: The Edge output format string (for example, `audio-24khz-48kbitrate-mono-mp3`).
    /// - Returns: Audio bytes for the synthesized speech.
    /// - Throws: Any error produced by the underlying WebSocket stream.
    public func synthesize(
        text: String,
        config: TTSConfig = try! TTSConfig(),
        outputFormat: String = "audio-24khz-48kbitrate-mono-mp3"
    ) async throws -> Data {
        var audio = Data()
        for try await event in stream(text: text, config: config, outputFormat: outputFormat) {
            if case .audio(let chunk) = event {
                audio.append(chunk)
            }
        }
        return audio
    }

    /// Streams synthesis events for the given text.
    ///
    /// The returned stream yields ``StreamEvent`` values:
    /// - `.audio(Data)` containing MPEG audio frames.
    /// - `.boundary(...)` metadata events when boundary tracking is enabled in the provided config.
    ///
    /// - Parameters:
    ///   - text: The text to synthesize.
    ///   - config: Synthesis configuration.
    ///   - outputFormat: The Edge output format string.
    /// - Returns: An asynchronous stream of synthesis events.
    public func stream(
        text: String,
        config: TTSConfig = try! TTSConfig(),
        outputFormat: String = "audio-24khz-48kbitrate-mono-mp3"
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performStream(text: text, config: config, outputFormat: outputFormat, continuation: continuation)
                    continuation.finish()
                } catch {
                    print(error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals

    private func performStream(
        text: String,
        config: TTSConfig,
        outputFormat: String,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        try await warmUpClockSkewIfNeeded()
        let escapedChunks = try TextSplitter.split(text: escapeXML(text), byteLimit: 4096)
        guard !escapedChunks.isEmpty else {
            throw EdgeTTSError.invalidParameter("Text is empty after sanitization")
        }

        var lastError: Error?

        attemptLoop: for _ in 0..<2 { // retry once with fresh token/connection
            let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let token = await DRM.generateSecMSGEC()
            let urlString = "\(EdgeTTSConstants.wssURL)&ConnectionId=\(connectionId)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
            guard let url = URL(string: urlString) else {
                throw EdgeTTSError.unexpectedResponse("Failed to create websocket URL")
            }

            let wsSession = makeWebSocketSession()
            var request = URLRequest(url: url)
            request.timeoutInterval = receiveTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            EdgeTTSConstants.wssHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
            // Add MUID cookie (matches Python edge-tts implementation)
            request.addValue("muid=\(EdgeTTSConstants.generateMUID());", forHTTPHeaderField: "Cookie")
            request.addValue("synthesize", forHTTPHeaderField: "Sec-WebSocket-Protocol")

            let websocket = wsSession.webSocketTask(with: request)
            websocket.resume()

            do {
                try await sendCommandRequest(websocket: websocket, boundary: config.boundary, outputFormat: outputFormat)

                var offsetCompensation: Int64 = 0
                var lastDurationOffset: Int64 = 0
                var audioReceived = false

                chunkStream: for chunk in escapedChunks {
                    let ssml = mkSSML(config: config, escapedText: chunk)
                    try await sendSSMLRequest(websocket: websocket, ssml: ssml)

                    chunkLoop: while true {
                        do {
                            let message = try await websocket.receive()
                            switch message {
                            case .string(let textMessage):
                                let data = Data(textMessage.utf8)
                                guard let headerRange = data.range(of: Data([13, 10, 13, 10])) else {
                                    throw EdgeTTSError.unexpectedResponse("Malformed text frame from websocket")
                                }
                                let headerData = data[..<headerRange.lowerBound]
                                let payload = data[headerRange.upperBound...]
                                let headers = parseHeaders(from: headerData)

                                guard let path = headers["Path"] else {
                                    throw EdgeTTSError.unexpectedResponse("Missing Path in text frame")
                                }

                                switch path {
                                case "audio.metadata":
                                    let parsed = try parseMetadata(payload, offsetCompensation: offsetCompensation)
                                    lastDurationOffset = parsed.offset + parsed.duration
                                    continuation.yield(.boundary(type: parsed.type, offset: parsed.offset, duration: parsed.duration, text: parsed.text))
                                case "turn.end":
                                    offsetCompensation = lastDurationOffset + 8_750_000
                                    break chunkLoop
                                case "turn.start", "response":
                                    continue
                                default:
                                    throw EdgeTTSError.unknownResponse("Unknown text path \(path)")
                                }
                            case .data(let data):
                                guard data.count >= 2 else {
                                    throw EdgeTTSError.unexpectedResponse("Binary frame too small to contain header length")
                                }
                                let headerLength = Int(data[0]) << 8 | Int(data[1])
                                guard data.count >= 2 + headerLength else {
                                    throw EdgeTTSError.unexpectedResponse("Binary frame header length exceeds data size")
                                }
                                let headerData = data[2..<(2 + headerLength)]
                                let payload = data[(2 + headerLength)...]
                                let headers = parseHeaders(from: headerData)
                                guard headers["Path"] == "audio" else {
                                    throw EdgeTTSError.unexpectedResponse("Binary frame did not contain audio data")
                                }
                                if let contentType = headers["Content-Type"], contentType != "audio/mpeg" {
                                    throw EdgeTTSError.unexpectedResponse("Unexpected Content-Type: \(contentType)")
                                }
                                if payload.isEmpty {
                                    continue
                                }
                                audioReceived = true
                                continuation.yield(.audio(payload))
                            @unknown default:
                                continue
                            }
                        } catch {
                            lastError = error
                            websocket.cancel(with: .goingAway, reason: nil)
                            continue attemptLoop
                        }
                    }
                }

                if !audioReceived {
                    throw EdgeTTSError.noAudioReceived
                }

                websocket.cancel(with: URLSessionWebSocketTask.CloseCode.normalClosure, reason: nil)
                return
            } catch {
                lastError = error
                websocket.cancel(with: .goingAway, reason: nil)
                continue
            }
        }

        throw EdgeTTSError.websocketError("WebSocket failed after retry: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func sendCommandRequest(websocket: URLSessionWebSocketTask, boundary: Boundary, outputFormat: String) async throws {
        let wordBoundaryEnabled = boundary == .word ? "true" : "false"
        let sentenceBoundaryEnabled = boundary == .sentence ? "true" : "false"
        let payload =
            "X-Timestamp:\(dateString())\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n"
            + "\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"\(sentenceBoundaryEnabled)\",\"wordBoundaryEnabled\":\"\(wordBoundaryEnabled)\"},\"outputFormat\":\"\(outputFormat)\"}}}}\r\n"
        try await websocket.send(.string(payload))
    }

    private func sendSSMLRequest(websocket: URLSessionWebSocketTask, ssml: String) async throws {
        let payload =
            "X-RequestId:\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(dateString())Z\r\n"
            + "Path:ssml\r\n"
            + "\r\n"
            + ssml
        try await websocket.send(.string(payload))
    }

    private func mkSSML(config: TTSConfig, escapedText: Data) -> String {
        let textString = String(data: escapedText, encoding: .utf8) ?? ""
        return """
        <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(config.voice)'><prosody pitch='\(config.pitch)' rate='\(config.rate)' volume='\(config.volume)'>\(textString)</prosody></voice></speak>
        """
    }

    private func parseHeaders(from data: Data) -> [String: String] {
        var headers: [String: String] = [:]
        guard let headerString = String(data: data, encoding: .utf8) else { return headers }
        for line in headerString.components(separatedBy: "\r\n") {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return headers
    }

    private func parseMetadata(_ data: Data, offsetCompensation: Int64) throws -> (type: Boundary, offset: Int64, duration: Int64, text: String) {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(MetadataEnvelope.self, from: data)
        for meta in envelope.metadata {
            guard let boundary = Boundary(rawValue: meta.type) else { continue }
            let offset = meta.data.offset + offsetCompensation
            return (boundary, offset, meta.data.duration, meta.data.text.text)
        }
        throw EdgeTTSError.unexpectedResponse("No WordBoundary metadata found")
    }

    private func escapeXML(_ string: String) -> String {
        var result = string
        let replacements: [(of: String, with: String)] = [
            ("&", "&amp;"),
            ("<", "&lt;"),
            (">", "&gt;"),
            ("\"", "&quot;"),
            ("'", "&apos;"),
        ]
        replacements.forEach { result = result.replacingOccurrences(of: $0.of, with: $0.with) }
        return result
    }

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private func makeWebSocketSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.timeoutIntervalForResource = receiveTimeout
        config.httpAdditionalHeaders = nil

        return URLSession(configuration: config, delegate: wsDelegate, delegateQueue: nil)
    }

    private func warmUpClockSkewIfNeeded() async throws {
        // A lightweight GET to the voices list endpoint to adjust clock skew on 403.
        let token = await DRM.generateSecMSGEC()
        let urlString = "\(EdgeTTSConstants.voiceListURL)&Sec-MS-GEC=\(token)&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        EdgeTTSConstants.voiceHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }
        // Add MUID cookie (matches Python edge-tts implementation)
        request.addValue("muid=\(EdgeTTSConstants.generateMUID());", forHTTPHeaderField: "Cookie")
        request.timeoutInterval = connectTimeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = connectTimeout
        config.timeoutIntervalForResource = connectTimeout
        let session = URLSession(configuration: config)

        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 {
            try await DRM.handleClientResponseError(http)
        }
    }
}

private final class WebSocketDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("WebSocket task completed with error: \(error.localizedDescription)")
        }
    }
}

extension EdgeTTSClient {
    /// Synthesizes text with optional language detection.
    ///
    /// If `forceLanguage` is provided, it is applied to the config via `config.setLanguage(_)`.
    /// Otherwise, when `autoDetectLanguage` is `true`, this method uses `NLLanguageRecognizer` to pick a dominant
    /// language and applies it to the synthesis config before calling ``synthesize(text:config:outputFormat:)``.
    ///
    /// - Parameters:
    ///   - text: The text to synthesize.
    ///   - config: Base synthesis configuration to start from.
    ///   - outputFormat: The Edge output format string.
    ///   - autoDetectLanguage: Whether to infer the language from the input text.
    ///   - forceLanguage: A locale identifier (for example `en-US` or `de-DE`) to force.
    /// - Returns: Audio bytes for the synthesized speech.
    /// - Throws: Any error produced by config language changes or synthesis.
    public func synthesize(
        text: String,
        config: TTSConfig = try! TTSConfig(),
        outputFormat: String = "audio-24khz-48kbitrate-mono-mp3",
        autoDetectLanguage: Bool = true,
        forceLanguage: String? = nil
    ) async throws -> Data {
        
        var config = config
        
        if let forceLanguage {
            try await config.setLanguage(forceLanguage)
        } else if autoDetectLanguage {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let language = recognizer.dominantLanguage {
                var detectedLanguage = language.rawValue
                switch detectedLanguage {
                case "de":
                    detectedLanguage = "de-DE"
                case "en":
                    detectedLanguage = "en-US"
                default:
                    break
                }
                try await config.setLanguage(detectedLanguage)
            } else {
                print("Language not recognized")
            }
        }
        
        return try await synthesize(text: text, config: config, outputFormat: outputFormat)
    }
        
}
