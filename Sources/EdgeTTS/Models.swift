import Foundation

/// Errors that can be thrown by the Edge TTS client and configuration layer.
///
/// Use these errors to diagnose invalid parameters, unexpected service responses,
/// and transport failures.
///
/// ```swift
/// do {
///     let config = try TTSConfig(voice: "en-US-EmmaMultilingualNeural")
///     _ = config
/// } catch let error as EdgeTTSError {
///     print(error.localizedDescription)
/// }
/// ```
public enum EdgeTTSError: Error, LocalizedError {
    case unknownResponse(String)
    case unexpectedResponse(String)
    case noAudioReceived
    case websocketError(String)
    case skewAdjustmentFailed(String)
    case invalidParameter(String)

    public var errorDescription: String? {
        switch self {
        case .unknownResponse(let message),
             .unexpectedResponse(let message),
             .websocketError(let message),
             .skewAdjustmentFailed(let message),
             .invalidParameter(let message):
            return message
        case .noAudioReceived:
            return "No audio was received. Please verify that your parameters are correct."
        }
    }
}

/// The granularity used for text boundary metadata events emitted during synthesis.
///
/// Boundary events are surfaced as ``StreamEvent/boundary(type:offset:duration:text:)``.
public enum Boundary: String, Codable, Sendable {
    case word = "WordBoundary"
    case sentence = "SentenceBoundary"
}

/// Configuration for a text-to-speech synthesis request.
///
/// `TTSConfig` validates its fields and normalizes certain Microsoft short voice names
/// to the long "Microsoft Server Speech Text to Speech Voice (...)" form when possible.
///
/// ```swift
/// let config = try TTSConfig(
///     voice: "en-US-EmmaMultilingualNeural",
///     rate: "+0%",
///     volume: "+0%",
///     pitch: "+0Hz",
///     boundary: .sentence
/// )
/// ```
public struct TTSConfig: Sendable {
    public var voice: String
    public var rate: String
    public var volume: String
    public var pitch: String
    public var boundary: Boundary

    /// Creates a new configuration instance.
    ///
    /// - Parameters:
    ///   - voice: The voice identifier. Accepts Microsoft short names (e.g. `en-US-EmmaMultilingualNeural`) and
    ///     will attempt to normalize them to the long Microsoft voice format.
    ///   - rate: Speaking rate as a percentage string (e.g. `+0%`, `-50%`).
    ///   - volume: Volume as a percentage string (e.g. `+0%`, `-50%`).
    ///   - pitch: Pitch shift in Hertz (e.g. `+0Hz`, `-50Hz`).
    ///   - boundary: Boundary event granularity.
    ///
    /// - Throws: ``EdgeTTSError/invalidParameter(_:)`` if any parameter fails validation.
    public init(
        voice: String = "en-US-EmmaMultilingualNeural",
        rate: String = "+0%",
        volume: String = "+0%",
        pitch: String = "+0Hz",
        boundary: Boundary = .sentence
    ) throws {
        self.voice = voice
        self.rate = rate
        self.volume = volume
        self.pitch = pitch
        self.boundary = boundary
        try validate()
    }

    /// Validates and normalizes configuration values.
    ///
    /// - Throws: ``EdgeTTSError/invalidParameter(_:)`` when a field does not match the expected format.
    private mutating func validate() throws {
        // More permissive voice validation - just check it's not empty
        guard !voice.isEmpty else {
            throw EdgeTTSError.invalidParameter("Voice cannot be empty")
        }
        guard rate.range(of: #"^[\+\-]\d+%$"#, options: .regularExpression) != nil else {
            throw EdgeTTSError.invalidParameter("Rate must be like +0% or -50%")
        }
        guard volume.range(of: #"^[\+\-]\d+%$"#, options: .regularExpression) != nil else {
            throw EdgeTTSError.invalidParameter("Volume must be like +0% or -50%")
        }
        guard pitch.range(of: #"^[\+\-]\d+Hz$"#, options: .regularExpression) != nil else {
            throw EdgeTTSError.invalidParameter("Pitch must be like +0Hz or -50Hz")
        }

        if let match = voice.range(of: #"^([a-z]{2,})-([A-Z]{2,})-(.+Neural)$"#, options: [.regularExpression]) {
            let sub = String(voice[match])
            let parts = sub.split(separator: "-", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                let lang = parts[0]
                var region = parts[1]
                var name = parts[2]
                if let dash = name.firstIndex(of: "-") {
                    region.append("-" + name[..<dash])
                    name = String(name[name.index(after: dash)...])
                }
                voice = "Microsoft Server Speech Text to Speech Voice (\(lang)-\(region), \(name))"
            }
        }
    }
    
    /// Sets the voice by selecting the first available voice matching a locale substring.
    ///
    /// This is a convenience helper that queries available voices and updates ``voice``.
    ///
    /// - Parameter locale: A locale string to match (for example, `"en-US"` or `"ja-JP"`).
    /// - Throws: Any error thrown by the voice listing request.
    ///
    /// - Note: Matching uses `String.contains` against the voice's `locale`.
    public mutating func setLanguage(_ locale: String) async throws {
        let availableVoices = try await EdgeTTSClient().listVoices()
        if let voice = availableVoices.first(where: {$0.locale.contains(locale)}) {
            self.voice = voice.shortName
        }
    }
}

/// A streaming synthesis event emitted by the TTS websocket.
///
/// Events include raw audio chunks and text boundary metadata.
public enum StreamEvent {
    case audio(Data)
    case boundary(type: Boundary, offset: Int64, duration: Int64, text: String)
}

/// A word-level timecode from TTS synthesis, suitable for persistence.
///
/// Offsets and durations use the same 100-nanosecond tick unit returned by the
/// Edge TTS service. Convenience properties ``offsetSeconds`` and
/// ``durationSeconds`` convert to seconds.
///
/// ```swift
/// let result = try await client.synthesizeWithWordTimecodes(text: "Hello world")
/// for tc in result.timecodes {
///     print("\(tc.text) at \(tc.offsetSeconds)s")
/// }
/// ```
public struct WordTimecode: Codable, Sendable, Equatable {
    /// Offset from the start of the audio in 100-nanosecond units.
    public let offset: Int64
    /// Duration of the word in 100-nanosecond units.
    public let duration: Int64

    /// Offset from the start of the audio in seconds.
    public var offsetSeconds: Double {
        Double(offset) / 10_000_000
    }

    /// Duration of the word in seconds.
    public var durationSeconds: Double {
        Double(duration) / 10_000_000
    }
}

/// The complete result of a TTS synthesis with word-level timecodes.
///
/// Conforms to ``Codable`` so it can be serialized to JSON or another format for persistence.
///
/// ```swift
/// let result = try await client.synthesizeWithWordTimecodes(text: "Hello world")
/// let json = try JSONEncoder().encode(result)
/// try json.write(to: URL(fileURLWithPath: "result.json"))
/// ```
public struct TTSResult: Codable, Sendable {
    /// The complete synthesized audio data.
    public let audioData: Data
    /// Word-level timecodes aligned to ``audioData``.
    public let timecodes: [WordTimecode]
}

/// Additional metadata describing a voice (categories and personalities).
///
/// This mirrors the service payload under the `VoiceTag` key.
public struct VoiceTag: Codable, Sendable {
    public let contentCategories: [String]
    public let voicePersonalities: [String]

    enum CodingKeys: String, CodingKey {
        case contentCategories = "ContentCategories"
        case voicePersonalities = "VoicePersonalities"
    }

    public init(contentCategories: [String] = [], voicePersonalities: [String] = []) {
        self.contentCategories = contentCategories
        self.voicePersonalities = voicePersonalities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let categories = try container.decodeIfPresent([String].self, forKey: .contentCategories) ?? []
        let personalities = try container.decodeIfPresent([String].self, forKey: .voicePersonalities) ?? []
        self.init(contentCategories: categories, voicePersonalities: personalities)
    }
}

/// A voice returned by the Edge TTS voice listing endpoint.
///
/// Use ``shortName`` as the primary identifier when configuring synthesis via ``TTSConfig``.
public struct Voice: Codable, Sendable {
    public let name: String
    public let shortName: String
    public let gender: String
    public let locale: String
    public let localeName: String?
    public let sampleRateHertz: String?
    public let voiceType: String?
    public let status: String?
    public let voiceTag: VoiceTag?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case shortName = "ShortName"
        case gender = "Gender"
        case locale = "Locale"
        case localeName = "LocaleName"
        case sampleRateHertz = "SampleRateHertz"
        case voiceType = "VoiceType"
        case status = "Status"
        case voiceTag = "VoiceTag"
    }
}

struct MetadataEnvelope: Decodable {
    struct Metadata: Decodable {
        struct InnerData: Decodable {
            struct TextData: Decodable {
                let text: String

                enum CodingKeys: String, CodingKey {
                    case text = "Text"
                }
            }

            let offset: Int64
            let duration: Int64
            let text: TextData

            enum CodingKeys: String, CodingKey {
                case offset = "Offset"
                case duration = "Duration"
                case text
            }
        }

        let type: String
        let data: InnerData

        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case data = "Data"
        }
    }

    let metadata: [Metadata]

    enum CodingKeys: String, CodingKey {
        case metadata = "Metadata"
    }
}
