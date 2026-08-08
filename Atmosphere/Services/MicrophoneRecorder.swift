import AVFoundation
import Foundation

struct MicrophoneRecording: Equatable, Sendable {
    static let wavHeaderByteCount = 44

    let fileURL: URL
    let duration: TimeInterval
    let byteCount: Int

    let contentType = "audio/wav"

    /// A WAV with bytes beyond its header and a positive duration contains a
    /// recording. This deliberately does not reject silence; speech detection
    /// belongs to the transcription service.
    var containsAudio: Bool {
        duration > 0 && byteCount > Self.wavHeaderByteCount
    }

    func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum MicrophoneRecorderError: Error, Equatable, LocalizedError {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case couldNotStart
    case couldNotReadRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow microphone access in System Settings to use voice input."
        case .alreadyRecording:
            return "Voice recording is already active."
        case .notRecording:
            return "Voice recording has not started."
        case .couldNotStart:
            return "Atmosphere could not start the microphone."
        case .couldNotReadRecording:
            return "Atmosphere could not read the recorded audio."
        }
    }
}

/// Records a mono, 16 kHz, 16-bit PCM WAV suitable for Deepgram's local-file
/// prerecorded endpoint. Actor isolation keeps AVAudioRecorder on one executor.
actor MicrophoneRecorder {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    init() {
        Self.removeOrphanedRecordings()
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    @discardableResult
    func start() async throws -> URL {
        try Task.checkCancellation()
        guard recorder == nil else {
            throw MicrophoneRecorderError.alreadyRecording
        }
        guard await Self.hasMicrophonePermission() else {
            throw MicrophoneRecorderError.permissionDenied
        }
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atmosphere-Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.prepareToRecord() else {
                try? FileManager.default.removeItem(at: url)
                throw MicrophoneRecorderError.couldNotStart
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            try Task.checkCancellation()
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: url)
                throw MicrophoneRecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            return url
        } catch let error as MicrophoneRecorderError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Stops and returns the temporary WAV. The caller owns the returned file
    /// and should call `discard()` after transcription finishes.
    func stop() throws -> MicrophoneRecording {
        guard let recorder, let url = recordingURL else {
            throw MicrophoneRecorderError.notRecording
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        recordingURL = nil

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            try? FileManager.default.removeItem(at: url)
            throw MicrophoneRecorderError.couldNotReadRecording
        }

        return MicrophoneRecording(
            fileURL: url,
            duration: duration,
            byteCount: size.intValue
        )
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    private static func hasMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    static func removeOrphanedRecordings(
        in directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let recordingsDirectory = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("Atmosphere-Recordings", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "wav" {
            try? fileManager.removeItem(at: file)
        }
    }
}
