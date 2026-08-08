import Foundation

struct DeepgramTranscriptionOptions: Equatable, Sendable {
    var model = "nova-3-general"
    var smartFormat = true
    var minimumTranscriptConfidence = 0.65
    var minimumLanguageConfidence = 0.70
}

struct DeepgramTranscript: Equatable, Sendable {
    let text: String
    let confidence: Double?
    let requestID: String?
    let audioDuration: TimeInterval?
    let detectedLanguage: String?
    let languageConfidence: Double?
}

enum DeepgramTranscriptionError: Error, Equatable, LocalizedError {
    case noRecordedAudio
    case invalidEndpoint
    case invalidResponse
    case noSpeechDetected
    case server(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .noRecordedAudio:
            return "No audio was recorded."
        case .invalidEndpoint:
            return "The Deepgram endpoint could not be created."
        case .invalidResponse:
            return "Deepgram returned an unexpected response."
        case .noSpeechDetected:
            return "No text was detected in the recording."
        case .server(let statusCode, let message):
            return message.map { "Deepgram error \(statusCode): \($0)" }
                ?? "Deepgram returned error \(statusCode)."
        }
    }
}

/// Uploads a completed local recording to Deepgram's prerecorded endpoint.
/// The API key is loaded only while constructing the request and is never
/// persisted by this client or included in an error message.
final class DeepgramTranscriptionClient: @unchecked Sendable {
    private enum Attempt: CaseIterable {
        case english
        case hindi
        case hinglish
        case urdu

        var detectedLanguage: String? {
            switch self {
            case .english:
                return "en"
            case .hindi:
                return "hi"
            case .hinglish, .urdu:
                return nil
            }
        }

        var fixedLanguage: String? {
            switch self {
            case .english, .hindi:
                return nil
            case .hinglish:
                return "multi"
            case .urdu:
                return "ur"
            }
        }
    }

    private let credentialProvider: any DeepgramCredentialProviding
    private let session: URLSession
    private let endpoint: URL
    private let options: DeepgramTranscriptionOptions

    init(
        credentialProvider: any DeepgramCredentialProviding = DeepgramFileCredentialStore(),
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/listen")!,
        options: DeepgramTranscriptionOptions = DeepgramTranscriptionOptions()
    ) {
        self.credentialProvider = credentialProvider
        self.session = session
        self.endpoint = endpoint
        self.options = options
    }

    func transcribe(_ recording: MicrophoneRecording) async throws -> DeepgramTranscript {
        try Task.checkCancellation()
        guard recording.containsAudio else {
            throw DeepgramTranscriptionError.noRecordedAudio
        }

        return try await transcribe(
            fileURL: recording.fileURL,
            contentType: recording.contentType
        )
    }

    func transcribe(
        fileURL: URL,
        contentType: String = "audio/wav"
    ) async throws -> DeepgramTranscript {
        try Task.checkCancellation()
        let audio = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        return try await transcribe(audio: audio, contentType: contentType)
    }

    func transcribe(audio: Data, contentType: String = "audio/wav") async throws -> DeepgramTranscript {
        try Task.checkCancellation()
        guard !audio.isEmpty else {
            throw DeepgramTranscriptionError.noRecordedAudio
        }

        let apiKey = try credentialProvider.apiKey()
        for attempt in Attempt.allCases {
            try Task.checkCancellation()
            do {
                let transcript = try await transcribe(
                    audio: audio,
                    contentType: contentType,
                    apiKey: apiKey,
                    attempt: attempt
                )
                if accepts(transcript, for: attempt) {
                    return transcript
                }
            } catch DeepgramTranscriptionError.noSpeechDetected {
                continue
            }
        }

        throw DeepgramTranscriptionError.noSpeechDetected
    }

    private func transcribe(
        audio: Data,
        contentType: String,
        apiKey: String,
        attempt: Attempt
    ) async throws -> DeepgramTranscript {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DeepgramTranscriptionError.invalidEndpoint
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "model", value: options.model))
        queryItems.append(
            URLQueryItem(name: "smart_format", value: options.smartFormat ? "true" : "false")
        )
        if let detectedLanguage = attempt.detectedLanguage {
            queryItems.append(URLQueryItem(name: "detect_language", value: detectedLanguage))
        }
        if let fixedLanguage = attempt.fixedLanguage {
            queryItems.append(URLQueryItem(name: "language", value: fixedLanguage))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw DeepgramTranscriptionError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.upload(for: request, from: audio)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(DeepgramAPIErrorResponse.self, from: data)
            throw DeepgramTranscriptionError.server(
                statusCode: httpResponse.statusCode,
                message: apiError?.message
            )
        }

        return try DeepgramResponseParser.parse(data)
    }

    private func accepts(_ transcript: DeepgramTranscript, for attempt: Attempt) -> Bool {
        guard
            let confidence = transcript.confidence,
            confidence >= options.minimumTranscriptConfidence,
            hasCompatibleSubstantiveText(transcript.text, for: attempt)
        else {
            return false
        }

        guard let expectedLanguage = attempt.detectedLanguage else {
            return true
        }
        guard
            transcript.detectedLanguage?.lowercased() == expectedLanguage,
            let languageConfidence = transcript.languageConfidence,
            languageConfidence >= options.minimumLanguageConfidence
        else {
            return false
        }
        return true
    }

    private func hasCompatibleSubstantiveText(_ text: String, for attempt: Attempt) -> Bool {
        let scalars = text.unicodeScalars
        let digitCount = scalars.reduce(into: 0) { count, scalar in
            if CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        }
        let letters = scalars.filter { CharacterSet.letters.contains($0) }

        // Spoken numbers can be smart-formatted without retaining any letters.
        if letters.isEmpty {
            return digitCount > 0
        }

        let compatibleLetterCount = letters.reduce(into: 0) { count, scalar in
            if isCompatible(scalar, with: attempt) {
                count += 1
            }
        }

        // Require at least half of the actual letters to use the expected
        // script. This rejects a stray compatible character in an otherwise
        // mismatched transcript while retaining short one-letter utterances.
        return compatibleLetterCount > 0 && compatibleLetterCount * 2 >= letters.count
    }

    private func isCompatible(_ scalar: Unicode.Scalar, with attempt: Attempt) -> Bool {
        switch attempt {
        case .english:
            return Self.isLatin(scalar)
        case .hindi:
            return Self.isDevanagari(scalar)
        case .hinglish:
            return Self.isLatin(scalar) || Self.isDevanagari(scalar)
        case .urdu:
            return Self.isArabic(scalar)
        }
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            return true
        default:
            return false
        }
    }

    private static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }
}

enum DeepgramResponseParser {
    static func parse(_ data: Data) throws -> DeepgramTranscript {
        let response: DeepgramAPIResponse
        do {
            response = try JSONDecoder().decode(DeepgramAPIResponse.self, from: data)
        } catch {
            throw DeepgramTranscriptionError.invalidResponse
        }

        guard
            let channel = response.results.channels.first,
            let alternative = channel.alternatives.first
        else {
            throw DeepgramTranscriptionError.invalidResponse
        }
        let text = alternative.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DeepgramTranscriptionError.noSpeechDetected
        }

        return DeepgramTranscript(
            text: text,
            confidence: alternative.confidence,
            requestID: response.metadata?.requestID,
            audioDuration: response.metadata?.duration,
            detectedLanguage: channel.detectedLanguage,
            languageConfidence: channel.languageConfidence
        )
    }
}

private struct DeepgramAPIResponse: Decodable {
    struct Metadata: Decodable {
        let requestID: String?
        let duration: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case duration
        }
    }

    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable {
                let transcript: String
                let confidence: Double?
            }

            let alternatives: [Alternative]

            let detectedLanguage: String?
            let languageConfidence: Double?

            enum CodingKeys: String, CodingKey {
                case alternatives
                case detectedLanguage = "detected_language"
                case languageConfidence = "language_confidence"
            }
        }

        let channels: [Channel]
    }

    let metadata: Metadata?
    let results: Results
}

private struct DeepgramAPIErrorResponse: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
        case message = "err_msg"
    }
}
