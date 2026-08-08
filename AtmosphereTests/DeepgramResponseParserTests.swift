import Foundation
import XCTest
@testable import Atmosphere

final class DeepgramResponseParserTests: XCTestCase {
    func testParsesBestAlternativeAndMetadata() throws {
        let data = Data(
            #"{"metadata":{"request_id":"request-123","duration":1.25},"results":{"channels":[{"alternatives":[{"transcript":"  Quelle heure est-il ?  ","confidence":0.98}],"detected_language":"fr","language_confidence":0.96}]}}"#.utf8
        )

        let transcript = try DeepgramResponseParser.parse(data)

        XCTAssertEqual(transcript.text, "Quelle heure est-il ?")
        XCTAssertEqual(transcript.confidence, 0.98)
        XCTAssertEqual(transcript.requestID, "request-123")
        XCTAssertEqual(transcript.audioDuration, 1.25)
        XCTAssertEqual(transcript.detectedLanguage, "fr")
        XCTAssertEqual(transcript.languageConfidence, 0.96)
    }

    func testLanguageDetectionMetadataIsOptional() throws {
        let data = Data(
            #"{"results":{"channels":[{"alternatives":[{"transcript":"Bonjour","confidence":0.9}]}]}}"#.utf8
        )

        let transcript = try DeepgramResponseParser.parse(data)

        XCTAssertNil(transcript.detectedLanguage)
        XCTAssertNil(transcript.languageConfidence)
    }

    func testRejectsEmptyTranscriptAsNoSpeech() {
        let data = Data(
            #"{"results":{"channels":[{"alternatives":[{"transcript":"   ","confidence":0.0}]}]}}"#.utf8
        )

        XCTAssertThrowsError(try DeepgramResponseParser.parse(data)) { error in
            XCTAssertEqual(error as? DeepgramTranscriptionError, .noSpeechDetected)
        }
    }

    func testRejectsMissingChannels() {
        let data = Data(#"{"results":{"channels":[]}}"#.utf8)

        XCTAssertThrowsError(try DeepgramResponseParser.parse(data)) { error in
            XCTAssertEqual(error as? DeepgramTranscriptionError, .invalidResponse)
        }
    }

    func testRejectsMalformedResponse() {
        let data = Data(#"{"results":null}"#.utf8)

        XCTAssertThrowsError(try DeepgramResponseParser.parse(data)) { error in
            XCTAssertEqual(error as? DeepgramTranscriptionError, .invalidResponse)
        }
    }
}

final class DeepgramTranscriptionClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DeepgramRequestURLProtocol.reset()
    }

    override func tearDown() {
        DeepgramRequestURLProtocol.reset()
        super.tearDown()
    }

    func testAcceptsEnglishFirstWithRestrictedLanguageDetection() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "What time is it?",
            confidence: 0.98,
            detectedLanguage: "en",
            languageConfidence: 0.99
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01, 0x02, 0x03]))
        let requests = DeepgramRequestURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let queryItems = try queryItems(for: request)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token unit-test-api-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(queryItems["model"], "nova-3-general")
        XCTAssertEqual(queryItems["detect_language"], "en")
        XCTAssertEqual(queryItems["smart_format"], "true")
        XCTAssertNil(queryItems["language"])
        XCTAssertEqual(transcript.text, "What time is it?")
    }

    func testFallsThroughToHindiAfterLowEnglishLanguageConfidence() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "Namaste",
            confidence: 1.0,
            detectedLanguage: "en",
            languageConfidence: 0.01
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.97,
            detectedLanguage: "hi",
            languageConfidence: 0.999
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))
        let queries = try DeepgramRequestURLProtocol.capturedRequests().map(queryItems)

        XCTAssertEqual(transcript.text, "नमस्ते")
        XCTAssertEqual(queries.count, 2)
        XCTAssertEqual(queries[0]["detect_language"], "en")
        XCTAssertEqual(queries[1]["detect_language"], "hi")
        XCTAssertNil(queries[0]["language"])
        XCTAssertNil(queries[1]["language"])
    }

    func testFallsThroughToHinglishMultilingualModel() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "",
            confidence: 0.0,
            detectedLanguage: "en",
            languageConfidence: 0.0
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.64,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "कल meeting कितने बजे है?",
            confidence: 0.94
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))
        let queries = try DeepgramRequestURLProtocol.capturedRequests().map(queryItems)

        XCTAssertEqual(transcript.text, "कल meeting कितने बजे है?")
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries[0]["detect_language"], "en")
        XCTAssertEqual(queries[1]["detect_language"], "hi")
        XCTAssertEqual(queries[2]["language"], "multi")
        XCTAssertNil(queries[2]["detect_language"])
    }

    func testFallsThroughToUrduAfterIncompatibleHinglishScript() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "",
            confidence: 0.0,
            detectedLanguage: "en",
            languageConfidence: 0.0
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "",
            confidence: 0.0,
            detectedLanguage: "hi",
            languageConfidence: 0.0
        )
        DeepgramRequestURLProtocol.enqueueSuccess(transcript: "Привет", confidence: 0.99)
        DeepgramRequestURLProtocol.enqueueSuccess(transcript: "کیا وقت ہوا ہے؟", confidence: 0.96)
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))
        let queries = try DeepgramRequestURLProtocol.capturedRequests().map(queryItems)

        XCTAssertEqual(transcript.text, "کیا وقت ہوا ہے؟")
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(queries[3]["language"], "ur")
        XCTAssertNil(queries[3]["detect_language"])
    }

    func testRejectsAllUnreliableCandidatesAsNoSpeechAndReadsCredentialOnce() async throws {
        // A high transcript confidence cannot rescue the wrong script.
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 1.0,
            detectedLanguage: "en",
            languageConfidence: 1.0
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.64,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        DeepgramRequestURLProtocol.enqueueSuccess(transcript: "Привет", confidence: 1.0)
        DeepgramRequestURLProtocol.enqueueSuccess(transcript: "hello", confidence: 1.0)
        let credentialProvider = StubDeepgramCredentialProvider()
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: credentialProvider,
            session: session
        )

        do {
            _ = try await client.transcribe(audio: Data([0x01]))
            XCTFail("Expected noSpeechDetected")
        } catch {
            XCTAssertEqual(error as? DeepgramTranscriptionError, .noSpeechDetected)
        }

        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 4)
        XCTAssertEqual(credentialProvider.readCount, 1)
    }

    func testAcceptsNumeralOnlyTranscriptAtExactConfidenceThresholds() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "123",
            confidence: 0.65,
            detectedLanguage: "en",
            languageConfidence: 0.70
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))

        XCTAssertEqual(transcript.text, "123")
        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 1)
    }

    func testPunctuationAndMissingConfidenceFallThroughWithRequestSettingsIntact() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "…?!",
            confidence: 0.99,
            detectedLanguage: "en",
            languageConfidence: 0.99
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: nil,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "meeting कब है?",
            confidence: 0.91
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(
            audio: Data([0x11, 0x22, 0x33]),
            contentType: "audio/wav"
        )
        let requests = DeepgramRequestURLProtocol.capturedRequests()

        XCTAssertEqual(transcript.text, "meeting कब है?")
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            let query = try queryItems(for: request)
            XCTAssertEqual(query["model"], "nova-3-general")
            XCTAssertEqual(query["smart_format"], "true")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        }
    }

    func testRequiresMatchingDetectedLanguageBeforeAcceptingEnglish() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "Hello",
            confidence: 0.99,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.99,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))

        XCTAssertEqual(transcript.text, "नमस्ते")
        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 2)
    }

    func testServerErrorAbortsWithoutTryingAnotherLanguage() async throws {
        DeepgramRequestURLProtocol.enqueue(
            statusCode: 401,
            data: Data(#"{"err_msg":"Invalid credentials"}"#.utf8)
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.99,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        do {
            _ = try await client.transcribe(audio: Data([0x01]))
            XCTFail("Expected the server error")
        } catch {
            XCTAssertEqual(
                error as? DeepgramTranscriptionError,
                .server(statusCode: 401, message: "Invalid credentials")
            )
        }

        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 1)
    }

    func testInvalidResponseAbortsWithoutTryingAnotherLanguage() async throws {
        DeepgramRequestURLProtocol.enqueue(statusCode: 200, data: Data("not-json".utf8))
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.99,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        do {
            _ = try await client.transcribe(audio: Data([0x01]))
            XCTFail("Expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? DeepgramTranscriptionError, .invalidResponse)
        }

        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 1)
    }

    func testNetworkErrorAbortsWithoutTryingAnotherLanguage() async throws {
        DeepgramRequestURLProtocol.enqueue(error: URLError(.notConnectedToInternet))
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "नमस्ते",
            confidence: 0.99,
            detectedLanguage: "hi",
            languageConfidence: 0.99
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )

        do {
            _ = try await client.transcribe(audio: Data([0x01]))
            XCTFail("Expected the network error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 1)
    }

    func testCredentialErrorAbortsBeforeMakingARequest() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: FailingDeepgramCredentialProvider(),
            session: session
        )

        do {
            _ = try await client.transcribe(audio: Data([0x01]))
            XCTFail("Expected the credential error")
        } catch {
            XCTAssertEqual(error as? DeepgramCredentialError, .missingCredential)
        }

        XCTAssertTrue(DeepgramRequestURLProtocol.capturedRequests().isEmpty)
    }

    func testCancellationAbortsBeforeMakingARequest() async throws {
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.transcribe(audio: Data([0x01]))
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(DeepgramRequestURLProtocol.capturedRequests().isEmpty)
    }

    func testCustomThresholdsAreHonored() async throws {
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "Threshold test",
            confidence: 0.89,
            detectedLanguage: "en",
            languageConfidence: 0.89
        )
        DeepgramRequestURLProtocol.enqueueSuccess(
            transcript: "परीक्षण",
            confidence: 0.90,
            detectedLanguage: "hi",
            languageConfidence: 0.90
        )
        let session = makeStubbedSession()
        defer { session.invalidateAndCancel() }
        let client = DeepgramTranscriptionClient(
            credentialProvider: StubDeepgramCredentialProvider(),
            session: session,
            options: DeepgramTranscriptionOptions(
                minimumTranscriptConfidence: 0.90,
                minimumLanguageConfidence: 0.90
            )
        )

        let transcript = try await client.transcribe(audio: Data([0x01]))

        XCTAssertEqual(transcript.text, "परीक्षण")
        XCTAssertEqual(DeepgramRequestURLProtocol.capturedRequests().count, 2)
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramRequestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func queryItems(for request: URLRequest) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
    }
}

private final class StubDeepgramCredentialProvider: DeepgramCredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadCount = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func apiKey() throws -> String {
        lock.lock()
        storedReadCount += 1
        lock.unlock()
        return "unit-test-api-key"
    }
}

private struct FailingDeepgramCredentialProvider: DeepgramCredentialProviding {
    func apiKey() throws -> String {
        throw DeepgramCredentialError.missingCredential
    }
}

private final class DeepgramRequestURLProtocol: URLProtocol {
    private struct Stub {
        let statusCode: Int?
        let data: Data?
        let error: Error?
    }

    private static let lock = NSLock()
    private static var storedRequests: [URLRequest] = []
    private static var stubs: [Stub] = []

    static func reset() {
        lock.lock()
        storedRequests = []
        stubs = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func enqueue(statusCode: Int, data: Data) {
        lock.lock()
        stubs.append(Stub(statusCode: statusCode, data: data, error: nil))
        lock.unlock()
    }

    static func enqueue(error: Error) {
        lock.lock()
        stubs.append(Stub(statusCode: nil, data: nil, error: error))
        lock.unlock()
    }

    static func enqueueSuccess(
        transcript: String,
        confidence: Double?,
        detectedLanguage: String? = nil,
        languageConfidence: Double? = nil
    ) {
        var alternative: [String: Any] = ["transcript": transcript]
        if let confidence {
            alternative["confidence"] = confidence
        }
        var channel: [String: Any] = ["alternatives": [alternative]]
        if let detectedLanguage {
            channel["detected_language"] = detectedLanguage
        }
        if let languageConfidence {
            channel["language_confidence"] = languageConfidence
        }
        let data = try! JSONSerialization.data(
            withJSONObject: ["results": ["channels": [channel]]]
        )
        enqueue(statusCode: 200, data: data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
        let stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        Self.lock.unlock()

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard
            let url = request.url,
            let statusCode = stub.statusCode,
            let data = stub.data,
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
