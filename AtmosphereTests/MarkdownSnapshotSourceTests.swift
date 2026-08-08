import XCTest
@testable import Atmosphere

final class MarkdownSnapshotSourceTests: XCTestCase {
    func testFinalSnapshotReplaysToExistingAndRecreatedRows() async {
        let source = MarkdownSnapshotSource(initial: "**Starting**", isFinal: false)
        var firstRow = source.text.makeAsyncIterator()

        let initial = await firstRow.next()
        XCTAssertEqual(initial, "**Starting**")

        source.publish("## Finished\n\n- One\n- Two", isFinal: true)

        let finalForExistingRow = await firstRow.next()
        let existingRowEnd = await firstRow.next()
        XCTAssertEqual(finalForExistingRow, "## Finished\n\n- One\n- Two")
        XCTAssertNil(existingRowEnd)

        var recreatedRow = source.text.makeAsyncIterator()
        let finalForRecreatedRow = await recreatedRow.next()
        let recreatedRowEnd = await recreatedRow.next()
        XCTAssertEqual(finalForRecreatedRow, "## Finished\n\n- One\n- Two")
        XCTAssertNil(recreatedRowEnd)
    }
}
