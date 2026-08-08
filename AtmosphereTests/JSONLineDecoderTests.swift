import Foundation
import XCTest
@testable import Atmosphere

final class JSONLineDecoderTests: XCTestCase {
    func testSplitLineAcrossChunks() throws {
        var decoder = JSONLineDecoder()

        XCTAssertEqual(try decoder.append(Data(#"{"method":"turn/"#.utf8)), [])
        let lines = try decoder.append(Data(#"completed"}"#.utf8) + Data([0x0A]))

        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"method":"turn/completed"}"#])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testSeveralLinesCRLFAndEmptyLines() throws {
        var decoder = JSONLineDecoder()
        let data = Data("{\"id\":1}\r\n\n{\"id\":2}\n".utf8)

        let lines = try decoder.append(data)

        XCTAssertEqual(
            lines.map { String(decoding: $0, as: UTF8.self) },
            ["{\"id\":1}", "{\"id\":2}"]
        )
    }

    func testFinishReturnsUnterminatedRecord() throws {
        var decoder = JSONLineDecoder()
        _ = try decoder.append(Data("{\"id\":3}".utf8))

        let finalLine = try XCTUnwrap(decoder.finish())

        XCTAssertEqual(String(decoding: finalLine, as: UTF8.self), "{\"id\":3}")
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testRejectsOversizedRecord() throws {
        var decoder = JSONLineDecoder(maximumLineLength: 4)

        XCTAssertThrowsError(try decoder.append(Data("12345".utf8))) { error in
            XCTAssertEqual(
                error as? JSONLineDecoder.DecoderError,
                .lineTooLong(maximumBytes: 4)
            )
        }
    }
}
