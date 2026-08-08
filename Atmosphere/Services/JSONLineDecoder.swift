import Foundation

/// Incrementally splits a byte stream into newline-delimited JSON records.
///
/// `codex app-server --stdio` writes exactly one JSON-RPC message per line, but
/// `FileHandle` is free to deliver partial lines or several lines in one read.
struct JSONLineDecoder {
    enum DecoderError: Error, Equatable, LocalizedError {
        case lineTooLong(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .lineTooLong(let maximumBytes):
                return "The app server emitted a JSON line larger than \(maximumBytes) bytes."
            }
        }
    }

    private(set) var bufferedByteCount = 0

    private var buffer = Data()
    private let maximumLineLength: Int

    init(maximumLineLength: Int = 8 * 1_024 * 1_024) {
        precondition(maximumLineLength > 0)
        self.maximumLineLength = maximumLineLength
    }

    /// Adds an arbitrary stream chunk and returns every complete, non-empty
    /// record found in it. Both LF and CRLF are accepted.
    mutating func append(_ data: Data) throws -> [Data] {
        guard !data.isEmpty else { return [] }

        buffer.append(data)
        var lines: [Data] = []

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)

            if line.last == 0x0D {
                line.removeLast()
            }

            guard !line.isEmpty else { continue }
            guard line.count <= maximumLineLength else {
                buffer.removeAll(keepingCapacity: false)
                bufferedByteCount = 0
                throw DecoderError.lineTooLong(maximumBytes: maximumLineLength)
            }
            lines.append(line)
        }

        guard buffer.count <= maximumLineLength else {
            buffer.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
            throw DecoderError.lineTooLong(maximumBytes: maximumLineLength)
        }

        bufferedByteCount = buffer.count
        return lines
    }

    /// Returns a final unterminated record when the stream closes.
    mutating func finish() throws -> Data? {
        defer {
            buffer.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
        }

        if buffer.last == 0x0D {
            buffer.removeLast()
        }

        guard !buffer.isEmpty else { return nil }
        guard buffer.count <= maximumLineLength else {
            throw DecoderError.lineTooLong(maximumBytes: maximumLineLength)
        }
        return buffer
    }
}
